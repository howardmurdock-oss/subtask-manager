import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../push_service.dart';

// ---------------------------------------------------------------------------
// The direct line for a live toy session.
//
// The Worker's toy room introduces the two sides and carries the session
// until this line opens; after that every command and state update travels
// over a WebRTC data channel relayed by Cloudflare's TURN servers, which bill
// by data rather than by the hour, and the room goes quiet.
//
// Relay only: neither side ever learns the other's address. If the line
// can't be made, the session simply carries on through the room.
// ---------------------------------------------------------------------------

/// One end of a direct line. Signals it emits must reach the other end's
/// [handleSignal] (through the room); frames arrive on [onFrame] once open.
abstract class ToyPeer {
  /// Set by the app at startup. Null (as in tests) means sessions stay on
  /// the room.
  static ToyPeerFactory? factory;

  void Function(Map<String, dynamic> signal)? onSignal;
  void Function(String frame)? onFrame;
  void Function()? onOpen;

  /// The line closed or failed on its own (not through [close]).
  void Function()? onClosed;

  bool get isOpen;

  /// When the TURN login this line uses runs out; it must be replaced before.
  DateTime? get expiresAt;

  /// The offerer makes the data channel and the offer; the answerer waits.
  Future<void> start({required bool offerer});

  void handleSignal(Map<String, dynamic> signal);

  void send(String frame);

  Future<void> close();
}

typedef ToyPeerFactory = ToyPeer Function();

/// Short-lived TURN logins from the Worker, shared by every line on this
/// device until close to expiry.
class ToyIce {
  ToyIce._();

  static List<Map<String, dynamic>>? _servers;
  static DateTime? _expiresAt;
  static Future<bool>? _fetching;

  /// Never handed out with less than this left.
  static const Duration _margin = Duration(minutes: 15);

  static DateTime? get expiresAt => _expiresAt;

  static Future<List<Map<String, dynamic>>?> servers() async {
    final until = _expiresAt;
    if (_servers != null && until != null && DateTime.now().isBefore(until.subtract(_margin))) {
      return _servers;
    }
    final ok = await (_fetching ??= _fetch().whenComplete(() => _fetching = null));
    return ok ? _servers : null;
  }

  static Future<bool> _fetch() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.postUrl(Uri.parse('${PushService.workerBaseUrl}/toy/ice'));
      final res = await req.close().timeout(const Duration(seconds: 10));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return false;
      final m = jsonDecode(body) as Map;
      final list = (m['iceServers'] as List?)?.whereType<Map>().map((s) => Map<String, dynamic>.from(s)).toList() ??
          const <Map<String, dynamic>>[];
      if (list.isEmpty) return false;
      final ttl = (m['ttl'] as num?)?.toInt() ?? 3600;
      _servers = list;
      _expiresAt = DateTime.now().add(Duration(seconds: ttl));
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}

/// Data only. flutter_webrtc otherwise offers to receive audio and video,
/// which put 6 KB of codec lists in every offer - too big, once sealed, for
/// the room to carry, so no line ever opened.
const Map<String, dynamic> _dataOnly = {
  'mandatory': {'OfferToReceiveAudio': false, 'OfferToReceiveVideo': false},
  'optional': [],
};

/// A direct line over flutter_webrtc.
class WebRtcToyPeer extends ToyPeer {
  RTCPeerConnection? _pc;
  RTCDataChannel? _channel;
  bool _open = false;
  bool _ended = false;
  bool _remoteSet = false;
  DateTime? _expiresAt;
  final List<RTCIceCandidate> _early = [];

  /// Steps run one at a time, in the order they arrived: a candidate must
  /// never be added before the description it belongs to.
  Future<void> _chain = Future.value();

  @override
  bool get isOpen => _open;

  @override
  DateTime? get expiresAt => _expiresAt;

  void _step(Future<void> Function() step) {
    _chain = _chain.then((_) async {
      if (_ended) return;
      try {
        await step();
      } catch (_) {
        _end(notify: true);
      }
    });
  }

  @override
  Future<void> start({required bool offerer}) {
    _step(() async {
      final servers = await ToyIce.servers();
      if (servers == null) throw StateError('no TURN login');
      if (_ended) return;
      _expiresAt = ToyIce.expiresAt;
      final pc = await createPeerConnection({
        'iceServers': servers,
        // Every byte through Cloudflare: partners never see each other's IP.
        'iceTransportPolicy': 'relay',
      });
      if (_ended) {
        await pc.close();
        return;
      }
      _pc = pc;
      pc.onIceCandidate = (c) {
        final cand = c.candidate;
        if (cand == null || cand.isEmpty) return;
        onSignal?.call({'k': 'cand', 'c': cand, 'mid': c.sdpMid, 'idx': c.sdpMLineIndex});
      };
      pc.onConnectionState = (s) {
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          _end(notify: true);
        }
      };
      if (offerer) {
        _wire(await pc.createDataChannel('toy', RTCDataChannelInit()..ordered = true));
        final offer = await pc.createOffer(_dataOnly);
        await pc.setLocalDescription(offer);
        onSignal?.call({'k': 'offer', 'sdp': offer.sdp});
      } else {
        pc.onDataChannel = _wire;
      }
    });
    return _chain;
  }

  void _wire(RTCDataChannel channel) {
    _channel = channel;
    channel.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelOpen) {
        _opened();
      } else if (s == RTCDataChannelState.RTCDataChannelClosed) {
        _end(notify: true);
      }
    };
    channel.onMessage = (m) {
      if (!m.isBinary) onFrame?.call(m.text);
    };
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) _opened();
  }

  void _opened() {
    if (_open || _ended) return;
    _open = true;
    onOpen?.call();
  }

  @override
  void handleSignal(Map<String, dynamic> signal) {
    _step(() async {
      final pc = _pc;
      if (pc == null) return;
      switch (signal['k']) {
        case 'offer':
          await pc.setRemoteDescription(RTCSessionDescription(signal['sdp'] as String?, 'offer'));
          await _remoteReady(pc);
          final answer = await pc.createAnswer(_dataOnly);
          await pc.setLocalDescription(answer);
          onSignal?.call({'k': 'answer', 'sdp': answer.sdp});
          break;
        case 'answer':
          await pc.setRemoteDescription(RTCSessionDescription(signal['sdp'] as String?, 'answer'));
          await _remoteReady(pc);
          break;
        case 'cand':
          final c = RTCIceCandidate(
            signal['c'] as String?,
            signal['mid'] as String?,
            (signal['idx'] as num?)?.toInt(),
          );
          if (_remoteSet) {
            await pc.addCandidate(c);
          } else {
            _early.add(c);
          }
          break;
      }
    });
  }

  Future<void> _remoteReady(RTCPeerConnection pc) async {
    _remoteSet = true;
    for (final c in _early) {
      await pc.addCandidate(c);
    }
    _early.clear();
  }

  @override
  void send(String frame) {
    if (!_open) return;
    try {
      _channel?.send(RTCDataChannelMessage(frame));
    } catch (_) {}
  }

  void _end({required bool notify}) {
    if (_ended) return;
    _ended = true;
    _open = false;
    final channel = _channel;
    final pc = _pc;
    _channel = null;
    _pc = null;
    // Not awaited: closing must never hold up the session falling back.
    () async {
      try {
        await channel?.close();
      } catch (_) {}
      try {
        await pc?.close();
      } catch (_) {}
    }();
    if (notify) onClosed?.call();
  }

  @override
  Future<void> close() async => _end(notify: false);
}
