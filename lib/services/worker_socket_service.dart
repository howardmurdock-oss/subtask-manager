import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'push_service.dart';

/// A live connection to the Worker, for devices FCM cannot reach.
///
/// Windows and Linux have no `firebase_messaging` implementation, so desktop
/// has been receiving over a shared public relay this project neither controls
/// nor can keep off a rate limit. This connects to the topic's hub in the
/// Worker instead: messages arrive the moment they are sent, and anything that
/// arrived while the machine was off is collected on reconnect by sequence
/// number.
///
/// Receiving only. Sending already goes through the Worker from every platform.
abstract class HubChannel {
  Stream<dynamic> get stream;
  void send(String data);
  Future<void> close();
}

typedef HubConnector = Future<HubChannel> Function(Uri url);
typedef HubRegistrar = Future<bool> Function(String topic, String clientId);

class _IoHubChannel implements HubChannel {
  _IoHubChannel(this._socket);

  final WebSocket _socket;

  @override
  Stream<dynamic> get stream => _socket;

  @override
  void send(String data) => _socket.add(data);

  @override
  Future<void> close() async {
    try {
      await _socket.close();
    } catch (_) {}
  }
}

class WorkerSocketService {
  WorkerSocketService({HubConnector? connector, HubRegistrar? registrar})
      : _connect = connector ?? _connectOverIo,
        _register = registrar ?? _registerOverHttp;

  final HubConnector _connect;
  final HubRegistrar _register;

  /// Highest sequence number already handled, per topic. Sent on connect so
  /// the hub replays only what this device actually missed.
  static String cursorKey(String topic) => 'worker_hub_cursor_$topic';
  static const String statusKey = 'worker_hub_status_v1';
  static const String _registeredAtKey = 'worker_hub_registered_at_v1';
  static const String _registeredTopicKey = 'worker_hub_registered_topic_v1';

  /// Re-claimed periodically so a registration that goes missing - a pruned
  /// row, a Worker restored from an older state - comes back on its own
  /// rather than leaving senders falling back to the relay forever.
  static const Duration _reregisterAfter = Duration(hours: 12);

  /// Receiving here is for platforms FCM does not serve. Android has push, and
  /// running both would mean two transports competing to deliver the same
  /// message.
  static bool get isSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  static const Duration _minBackoff = Duration(seconds: 2);
  static const Duration _maxBackoff = Duration(minutes: 1);
  static const Duration _pingInterval = Duration(seconds: 45);

  HubChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  Duration _backoff = _minBackoff;
  bool _stopped = true;
  String _topic = '';
  String _clientId = '';
  Future<void> Function(String raw)? _onPayload;

  bool get isConnected => _channel != null;

  /// Begins receiving for [topic] and keeps the connection up.
  Future<void> start({
    required String topic,
    required String clientId,
    required Future<void> Function(String raw) onPayload,
  }) async {
    if (!isSupported || topic.isEmpty) return;
    if (!_stopped && _topic == topic) return; // Already running for this topic.
    await stop();
    _stopped = false;
    _topic = topic;
    _clientId = clientId;
    _onPayload = onPayload;
    await _openConnection();
  }

  Future<void> stop() async {
    _stopped = true;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _reconnectTimer = null;
    _pingTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    final channel = _channel;
    _channel = null;
    await channel?.close();
  }

  Future<void> _openConnection() async {
    if (_stopped) return;
    try {
      final since = await _cursor();
      final url = Uri.parse('${PushService.workerBaseUrl}/subscribe')
          .replace(scheme: 'wss', queryParameters: {'topic': _topic, 'since': '$since'});

      final channel = await _connect(url);
      if (_stopped) {
        await channel.close();
        return;
      }
      _channel = channel;
      _backoff = _minBackoff;
      await _recordStatus('connected');
      // Registration is what tells a sender that this topic has a desktop
      // listening, so /send stops answering "nobody here" and falling back to
      // the relay. Done after connecting, so we only claim a topic we are
      // actually listening on.
      unawaited(_claimTopic());

      _subscription = channel.stream.listen(
        (data) => unawaited(_handleFrame(data)),
        onDone: () => _scheduleReconnect('closed'),
        onError: (Object e) => _scheduleReconnect('$e'),
        cancelOnError: true,
      );

      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(_pingInterval, (_) {
        try {
          _channel?.send('ping');
        } catch (e) {
          _scheduleReconnect('ping failed: $e');
        }
      });
    } catch (e) {
      _scheduleReconnect('$e');
    }
  }

  Future<void> _handleFrame(dynamic data) async {
    if (data is! String || data.isEmpty || data == 'pong') return;
    try {
      final frame = jsonDecode(data);
      if (frame is! Map) return;
      final payload = frame['p'];
      final seq = (frame['seq'] as num?)?.toInt();
      if (payload is! String || payload.isEmpty) return;

      // The payload is the same encrypted SyncMessage the relay carries, so it
      // goes through the identical decode-and-dispatch path and inherits
      // addressing, dedup and the occurrence ledger.
      await _onPayload?.call(payload);

      // Advanced only after handling, so a crash mid-message replays it rather
      // than skipping it.
      if (seq != null) await _saveCursor(seq);
      await _recordStatus('received #$seq (${frame['k'] ?? 'sync'})');
    } catch (e) {
      if (kDebugMode) print('WorkerSocketService: bad frame: $e');
    }
  }

  void _scheduleReconnect(String reason) {
    if (_stopped) return;
    unawaited(_recordStatus('disconnected: $reason'));
    _pingTimer?.cancel();
    _subscription?.cancel();
    _subscription = null;
    final channel = _channel;
    _channel = null;
    unawaited(channel?.close() ?? Future<void>.value());

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_backoff, () {
      // Widening backoff: a Worker that is down should not be hammered, and a
      // laptop that wakes to no network should not spin.
      _backoff = _backoff * 2 > _maxBackoff ? _maxBackoff : _backoff * 2;
      unawaited(_openConnection());
    });
  }

  Future<void> _claimTopic() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final last = DateTime.tryParse(prefs.getString(_registeredAtKey) ?? '');
      final fresh = last != null &&
          prefs.getString(_registeredTopicKey) == _topic &&
          DateTime.now().difference(last) < _reregisterAfter;
      if (fresh) return;
      if (await _register(_topic, _clientId)) {
        await prefs.setString(_registeredAtKey, DateTime.now().toIso8601String());
        await prefs.setString(_registeredTopicKey, _topic);
      }
    } catch (_) {}
  }

  Future<int> _cursor() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return prefs.getInt(cursorKey(_topic)) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _saveCursor(int seq) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (seq > (prefs.getInt(cursorKey(_topic)) ?? 0)) {
        await prefs.setInt(cursorKey(_topic), seq);
      }
    } catch (_) {}
  }

  Future<void> _recordStatus(String status) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(statusKey, '${DateTime.now().toIso8601String()} | $status');
    } catch (_) {}
  }

  /// Last connection or delivery outcome, for the diagnostics panel.
  static Future<String> lastStatus() async {
    if (!isSupported) return 'not used on this platform';
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return prefs.getString(statusKey) ?? 'never connected';
    } catch (_) {
      return 'unavailable';
    }
  }

  static Future<HubChannel> _connectOverIo(Uri url) async {
    final socket = await WebSocket.connect(url.toString())
        .timeout(const Duration(seconds: 15));
    return _IoHubChannel(socket);
  }

  /// Claims this topic for a desktop device. The client id is this device's
  /// own id, not an FCM token; the Worker keeps them apart by platform.
  static Future<bool> _registerOverHttp(String topic, String clientId) async {
    if (clientId.isEmpty) return false;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client
          .postUrl(Uri.parse('${PushService.workerBaseUrl}/register'))
          .timeout(const Duration(seconds: 10));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'topic': topic,
        'token': clientId,
        'platform': Platform.isWindows
            ? 'windows'
            : (Platform.isMacOS ? 'macos' : 'linux'),
      }));
      final response = await request.close().timeout(const Duration(seconds: 15));
      await response.drain<void>();
      return response.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
