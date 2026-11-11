import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/security/encryption_helper.dart';
import '../../models/cadence_config.dart';
import '../../models/partner_contact.dart';
import '../partner_service.dart';
import '../push_service.dart';
import '../worker_socket_service.dart' show HubChannel, HubConnector;
import 'toy_patterns.dart';
import 'toy_peer.dart';
import 'toy_player.dart';
import 'toy_service.dart';

// ---------------------------------------------------------------------------
// Live toy control between partners.
//
// The toy's owner joins a relay room in the Worker while a toy is connected
// and at least one partner is allowed; a partner's control panel joins the
// same room while open. Commands are sealed (AES-GCM) under the secret the two
// share from pairing - so the secret a frame opens with is also who sent it,
// and nobody else in the room can forge or read it. The room stores nothing.
//
// Everything is decided on the owner's device: who is allowed, the strength
// ceiling, one partner in control at a time, and that the toy stops when the
// partner in control goes quiet.
//
// Once a partner is let in, their panel offers a direct line (ToyPeer: WebRTC
// relayed by Cloudflare TURN), signalled through the room as 'rtc' frames.
// When it opens, both sides send everything over it instead and the room
// sleeps; if it fails or closes, they carry on through the room as before.
// The frames themselves are the same either way.
// ---------------------------------------------------------------------------

/// Envelope version for live frames: authenticated, unlike v1.
const int _sealVersion = 2;

String _seal(Map<String, dynamic> body, String secret) =>
    EncryptionHelper.encryptString(jsonEncode(body), secret, version: _sealVersion);

Map<String, dynamic>? _open(String frame, String secret) {
  try {
    final decoded = jsonDecode(EncryptionHelper.decryptString(frame, secret));
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  } catch (_) {
    return null;
  }
}

/// A frame from the room itself, rather than relayed from a person.
class ToyPresence {
  const ToyPresence({required this.ownerOnline, required this.controllers});
  final bool ownerOnline;
  final int controllers;

  static ToyPresence? parse(String frame) {
    if (!frame.startsWith('{')) return null;
    try {
      final m = jsonDecode(frame);
      if (m is! Map || m['sys'] != 'presence') return null;
      return ToyPresence(
        ownerOnline: m['owner'] == true,
        controllers: (m['controllers'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

Future<HubChannel> _connectOverIo(Uri url) async {
  final socket = await WebSocket.connect(url.toString()).timeout(const Duration(seconds: 10));
  return _IoChannel(socket);
}

class _IoChannel implements HubChannel {
  _IoChannel(this._socket);
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

/// One side's connection to a toy room, kept up while wanted.
class ToyRoomSocket {
  ToyRoomSocket({
    required this.topic,
    required this.role,
    required this.onFrame,
    this.onConnectedChanged,
    HubConnector? connector,
  }) : _connect = connector ?? _connectOverIo;

  final String topic;

  /// 'owner' or 'ctl'.
  final String role;
  final void Function(String frame) onFrame;
  final void Function(bool connected)? onConnectedChanged;
  final HubConnector _connect;

  HubChannel? _channel;
  StreamSubscription? _sub;
  Timer? _ping;
  Timer? _retry;
  Duration _backoff = const Duration(seconds: 1);
  bool _wanted = false;

  bool get isConnected => _channel != null;

  /// The most the Worker's room carries in one frame (TOY_MAX_FRAME there);
  /// anything bigger is dropped without a word.
  static const int maxFrame = 8 * 1024;

  static Uri urlFor(String topic, String role) => Uri.parse('${PushService.workerBaseUrl}/toy')
      .replace(scheme: 'wss', queryParameters: {'topic': topic, 'role': role});

  Future<void> open() async {
    if (_wanted) return;
    _wanted = true;
    await _attempt();
  }

  Future<void> _attempt() async {
    if (!_wanted || _channel != null) return;
    try {
      final channel = await _connect(urlFor(topic, role));
      if (!_wanted) {
        await channel.close();
        return;
      }
      _channel = channel;
      _backoff = const Duration(seconds: 1);
      onConnectedChanged?.call(true);
      _sub = channel.stream.listen(
        (data) {
          if (data is String && data != 'pong') onFrame(data);
        },
        onDone: _lost,
        onError: (_) => _lost(),
        cancelOnError: true,
      );
      _ping?.cancel();
      _ping = Timer.periodic(const Duration(seconds: 25), (_) => send('ping'));
    } catch (_) {
      _scheduleRetry();
    }
  }

  void _lost() {
    _sub?.cancel();
    _sub = null;
    _ping?.cancel();
    final had = _channel != null;
    _channel = null;
    if (had) onConnectedChanged?.call(false);
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (!_wanted) return;
    _retry?.cancel();
    _retry = Timer(_backoff, () {
      final next = _backoff * 2;
      _backoff = next > const Duration(seconds: 30) ? const Duration(seconds: 30) : next;
      _attempt();
    });
  }

  void send(String frame) {
    try {
      _channel?.send(frame);
    } catch (_) {}
  }

  Future<void> close() async {
    _wanted = false;
    _retry?.cancel();
    _ping?.cancel();
    await _sub?.cancel();
    _sub = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) onConnectedChanged?.call(false);
    await channel?.close();
  }
}

/// What the owner's device needs from the rest of the app.
abstract class ToyRemoteContext {
  String get myCode;
  String get myName;

  /// Paired, unblocked partners (never yourself).
  List<PartnerContact> get partners;

  /// Tells [partner] whether your toy is available to them right now.
  Future<void> sendToyStatus(PartnerContact partner, {required bool online, String? toyName});

  String topicFor(String code);
}

/// The toy owner's side: who may control, and carrying out what they send.
class ToyRemoteHost extends ChangeNotifier {
  ToyRemoteHost({
    ToyPlayer? player,
    ToyService? toy,
    HubConnector? connector,
    ToyPeerFactory? peers,
    this.quietLimit = const Duration(seconds: 6),
  })  : _player = player ?? ToyPlayer.instance,
        _toyService = toy ?? ToyService.instance,
        _connector = connector,
        _peerFactory = peers;

  static final ToyRemoteHost instance = ToyRemoteHost();

  static const String allowedKey = 'toy_remote_allowed_v1';
  static const String capKey = 'toy_remote_cap_v1';
  static const String pausedKey = 'toy_remote_paused_v1';

  final ToyPlayer _player;
  final ToyService _toyService;
  final HubConnector? _connector;
  final ToyPeerFactory? _peerFactory;
  ToyPeerFactory? get _peers => _peerFactory ?? ToyPeer.factory;

  /// Partner code -> their direct line, open or still being made.
  final Map<String, _HostLine> _lines = {};

  /// How long the partner in control may go silent before the toy stops.
  final Duration quietLimit;

  ToyRemoteContext? _context;
  ToyRoomSocket? _room;
  Timer? _watchdog;
  Timer? _stateDebounce;
  bool _started = false;
  bool _wasOnline = false;
  String? _announcedToyName;

  final Set<String> _allowed = {};
  int _cap = 20;
  bool _paused = false;

  String? _controller;
  DateTime? _lastHeard;

  /// Partner code -> when they were last heard in the room. State goes only
  /// to partners actually watching.
  final Map<String, DateTime> _watching = {};

  Set<String> get allowed => Set.unmodifiable(_allowed);
  int get cap => _cap;
  bool get paused => _paused;
  bool get roomConnected => _room?.isConnected ?? false;

  /// Whether [partner]'s session runs over a direct line right now.
  bool isDirect(PartnerContact partner) =>
      _lines[PartnerService.normalizeCode(partner.pairingCode)]?.peer.isOpen ?? false;

  /// The partner in control right now, if any.
  PartnerContact? get controller => _controller == null ? null : _contactByCode(_controller!);
  bool isAllowed(PartnerContact c) => _allowed.contains(PartnerService.normalizeCode(c.pairingCode));

  /// Whether the toy is open to partners: connected, someone allowed.
  bool get isOnline => _toyService.isConnected && _allowedPartners().isNotEmpty;

  Future<void> start(ToyRemoteContext context) async {
    _context = context;
    if (_started) return;
    _started = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _allowed
        ..clear()
        ..addAll(prefs.getStringList(allowedKey) ?? const []);
      _cap = (prefs.getInt(capKey) ?? 20).clamp(1, 20);
      _paused = prefs.getBool(pausedKey) ?? false;
    } catch (_) {}
    _toyService.addListener(_onToyChanged);
    _player.addListener(_onPlayerChanged);
    _onToyChanged();
  }

  Future<void> stopService() async {
    _toyService.removeListener(_onToyChanged);
    _player.removeListener(_onPlayerChanged);
    _started = false;
    await _closeRoom();
  }

  // ---- Settings -----------------------------------------------------------

  Future<void> setAllowed(PartnerContact partner, bool allow) async {
    final code = PartnerService.normalizeCode(partner.pairingCode);
    if (code.isEmpty) return;
    final changed = allow ? _allowed.add(code) : _allowed.remove(code);
    if (!changed) return;
    if (!allow && _controller == code) _release(stopToy: true);
    // Before the room can close behind it, if this was the last partner.
    if (!allow) {
      _sendTo(partner, {'t': 'denied'});
      _closeLine(code);
    }
    await _saveSettings();
    final wasOnline = _wasOnline;
    // Going from nobody allowed to someone tells everyone allowed, this
    // partner included; otherwise only this partner needs telling.
    _onToyChanged();
    if (wasOnline) {
      await _context?.sendToyStatus(partner, online: allow, toyName: _toyService.connectedToy?.name);
    }
    notifyListeners();
  }

  Future<void> setCap(int cap) async {
    _cap = cap.clamp(1, 20);
    if (_controller != null) _toyService.outputCap = _cap;
    await _saveSettings();
    _scheduleState();
    notifyListeners();
  }

  /// Stops partners from controlling for now, without un-allowing anyone.
  Future<void> setPaused(bool paused) async {
    _paused = paused;
    if (paused) _release(stopToy: true);
    await _saveSettings();
    _scheduleState();
    notifyListeners();
  }

  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(allowedKey, _allowed.toList());
      await prefs.setInt(capKey, _cap);
      await prefs.setBool(pausedKey, _paused);
    } catch (_) {}
  }

  /// The owner acting on their own toy: whoever was in control loses it.
  void ownerTookOver() {
    if (_controller != null) _release(stopToy: false);
  }

  /// The owner's Stop: stills the toy and ends a partner's turn.
  void stopNow() {
    _release(stopToy: true);
    _player.stop();
  }

  // ---- Lifecycle ----------------------------------------------------------

  List<PartnerContact> _allowedPartners() => (_context?.partners ?? const <PartnerContact>[])
      .where((c) => !c.isBlocked && _allowed.contains(PartnerService.normalizeCode(c.pairingCode)))
      .toList();

  PartnerContact? _contactByCode(String code) {
    for (final c in _context?.partners ?? const <PartnerContact>[]) {
      if (PartnerService.normalizeCode(c.pairingCode) == code) return c;
    }
    return null;
  }

  void _onToyChanged() {
    final online = isOnline;
    final toyName = _toyService.connectedToy?.name;
    if (online && _room == null) _openRoom();
    if (!online && _room != null) {
      _release(stopToy: false);
      _closeRoom();
    }
    if (online != _wasOnline || (online && toyName != _announcedToyName)) {
      _wasOnline = online;
      _announcedToyName = toyName;
      for (final p in _allowedPartners()) {
        _context?.sendToyStatus(p, online: online, toyName: toyName);
      }
    }
    _scheduleState();
    notifyListeners();
  }

  /// Partners watching see the toy change, including a metronome that ran
  /// its length on its own.
  void _onPlayerChanged() => _scheduleState();

  void _openRoom() {
    final ctx = _context;
    if (ctx == null || ctx.myCode.isEmpty) return;
    _room = ToyRoomSocket(
      topic: ctx.topicFor(ctx.myCode),
      role: 'owner',
      onFrame: _onFrame,
      onConnectedChanged: (_) => notifyListeners(),
      connector: _connector,
    );
    _room!.open();
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) => _checkQuiet());
  }

  Future<void> _closeRoom() async {
    _watchdog?.cancel();
    _watchdog = null;
    final room = _room;
    _room = null;
    _watching.clear();
    for (final code in _lines.keys.toList()) {
      _closeLine(code);
    }
    await room?.close();
  }

  void _checkQuiet() {
    final heard = _lastHeard;
    if (_controller != null && heard != null && DateTime.now().difference(heard) > quietLimit) {
      _release(stopToy: true);
    }
    final cutoff = DateTime.now().subtract(const Duration(seconds: 30));
    _watching.removeWhere((_, at) => at.isBefore(cutoff));
    for (final code in _lines.keys.toList()) {
      final line = _lines[code]!;
      final expires = line.peer.expiresAt;
      if (!_watching.containsKey(code) && line.startedAt.isBefore(cutoff)) {
        _closeLine(code);
      } else if (expires != null && DateTime.now().isAfter(expires.subtract(const Duration(minutes: 5)))) {
        // Its TURN login is running out. The panel makes a new line.
        _closeLine(code, tell: true);
      }
    }
  }

  void _release({required bool stopToy}) {
    final had = _controller != null;
    _controller = null;
    _lastHeard = null;
    _toyService.outputCap = null;
    if (had && stopToy) _player.stop();
    if (had) {
      _scheduleState();
      notifyListeners();
    }
  }

  // ---- Frames -------------------------------------------------------------

  /// Handles one frame from the room. Public for tests.
  @visibleForTesting
  void handleFrame(String frame) => _onFrame(frame);

  void _onFrame(String frame) {
    final presence = ToyPresence.parse(frame);
    if (presence != null) {
      _scheduleState();
      return;
    }

    // The secret a frame opens with says who sent it.
    PartnerContact? sender;
    Map<String, dynamic>? body;
    for (final c in _context?.partners ?? const <PartnerContact>[]) {
      if (c.pairingSecret.isEmpty) continue;
      body = _open(frame, c.pairingSecret);
      if (body != null) {
        sender = c;
        break;
      }
    }
    if (sender == null || body == null) return;
    final code = PartnerService.normalizeCode(sender.pairingCode);

    if (sender.isBlocked || !_allowed.contains(code)) {
      _sendTo(sender, {'t': 'denied'});
      return;
    }

    _watching[code] = DateTime.now();
    final type = body['t'];
    if (type == 'hello') {
      _sendStateTo(sender);
      return;
    }
    if (type == 'hb') {
      if (_controller == code) _lastHeard = DateTime.now();
      return;
    }
    if (type == 'bye') {
      _watching.remove(code);
      _closeLine(code);
      if (_controller == code) _release(stopToy: true);
      return;
    }
    if (type == 'rtc') {
      _onRtc(sender, code, body);
      return;
    }

    if (_paused || !_toyService.isConnected) {
      _sendStateTo(sender);
      return;
    }
    final quietSince = _lastHeard;
    final current = _controller;
    if (current != null &&
        current != code &&
        quietSince != null &&
        DateTime.now().difference(quietSince) <= quietLimit) {
      // Someone else has it. They see who in the state.
      _sendStateTo(sender);
      return;
    }

    if (type == 'stop') {
      // From the partner in control, or with nobody in control.
      _player.stop();
      _release(stopToy: false);
      return;
    }

    if (current != code) {
      _controller = code;
      notifyListeners();
    }
    _lastHeard = DateTime.now();
    _toyService.outputCap = _cap;
    _apply(body);
  }

  void _apply(Map<String, dynamic> body) {
    int intOf(String key, int fallback) => (body[key] as num?)?.toInt() ?? fallback;
    switch (body['t']) {
      case 'level':
        _player.setLevel(intOf('v', 0));
        break;
      case 'pattern':
        final p = ToyPatternInfo.fromName(body['p'] as String?);
        if (p != null) _player.playPattern(p, intOf('v', 12));
        break;
      case 'strength':
        _player.setStrength(intOf('v', 12));
        break;
      case 'metronome':
        final cfg = body['cfg'];
        if (cfg is Map) {
          _player.startMetronome(
            CadenceConfig.fromJson(Map<String, dynamic>.from(cfg)),
            seconds: intOf('secs', 0).clamp(0, 3 * 60 * 60),
            strength: intOf('v', 12),
          );
        }
        break;
      case 'metronomeUpdate':
        final cfg = body['cfg'];
        if (cfg is Map) _player.updateMetronome(CadenceConfig.fromJson(Map<String, dynamic>.from(cfg)));
        break;
    }
    _scheduleState();
  }

  // ---- Direct lines -------------------------------------------------------

  /// Most lines one toy keeps at once, as the room's partner limit.
  static const int maxLines = 10;

  void _onRtc(PartnerContact sender, String code, Map<String, dynamic> body) {
    final id = body['id'];
    if (id is! String || id.isEmpty) return;
    final kind = body['k'];
    final existing = _lines[code];

    if (kind == 'offer') {
      final make = _peers;
      if (make == null || (existing == null && _lines.length >= maxLines)) {
        // Can't here: the panel stays on the room and stops asking.
        _sendTo(sender, {'t': 'rtc', 'k': 'end', 'id': id, 'final': true}, viaRoom: true);
        return;
      }
      _closeLine(code);
      final peer = make();
      final line = _HostLine(peer, id);
      _lines[code] = line;
      peer.onSignal = (s) => _sendTo(sender, {...s, 't': 'rtc', 'id': id}, viaRoom: true);
      peer.onFrame = _onFrame;
      peer.onOpen = notifyListeners;
      peer.onClosed = () {
        if (identical(_lines[code], line)) {
          _lines.remove(code);
          notifyListeners();
        }
      };
      peer.start(offerer: false);
      peer.handleSignal(body);
      return;
    }
    if (existing == null || existing.id != id) return;
    if (kind == 'end') {
      _closeLine(code);
    } else {
      existing.peer.handleSignal(body);
    }
  }

  void _closeLine(String code, {bool tell = false}) {
    final line = _lines.remove(code);
    if (line == null) return;
    if (tell) {
      final c = _contactByCode(code);
      if (c != null) _sendTo(c, {'t': 'rtc', 'k': 'end', 'id': line.id}, viaRoom: true);
    }
    line.peer.close();
    notifyListeners();
  }

  // ---- State out ----------------------------------------------------------

  Map<String, dynamic> stateFor(PartnerContact partner) {
    final toy = _toyService.connectedToy;
    final controller = _controller;
    final controllerContact = controller == null ? null : _contactByCode(controller);
    return {
      't': 'state',
      'toy': toy == null ? null : {'name': toy.name, 'battery': toy.batteryLevel},
      'paused': _paused,
      'cap': _cap,
      'activity': _player.activity.name,
      'level': _player.level,
      'pattern': _player.pattern?.name,
      'strength': _player.strength,
      'bpm': _player.currentBpm,
      'secs': _player.cadenceSeconds,
      'progress': _player.metronomeProgress,
      'speed': _toyService.currentSpeed,
      'youControl': controller != null && controller == PartnerService.normalizeCode(partner.pairingCode),
      'controllerName': controllerContact?.displayName,
    };
  }

  void _scheduleState() {
    if (_room == null || _stateDebounce != null) return;
    // At most four updates a second, however busy the toy is.
    _stateDebounce = Timer(const Duration(milliseconds: 250), () {
      _stateDebounce = null;
      for (final p in _allowedPartners()) {
        if (_watching.containsKey(PartnerService.normalizeCode(p.pairingCode))) _sendStateTo(p);
      }
    });
  }

  void _sendStateTo(PartnerContact partner) => _sendTo(partner, stateFor(partner));

  void _sendTo(PartnerContact partner, Map<String, dynamic> body, {bool viaRoom = false}) {
    if (partner.pairingSecret.isEmpty) return;
    final frame = _seal(body, partner.pairingSecret);
    final line = viaRoom ? null : _lines[PartnerService.normalizeCode(partner.pairingCode)];
    if (line != null && line.peer.isOpen) {
      line.peer.send(frame);
    } else {
      _room?.send(frame);
    }
  }
}

class _HostLine {
  _HostLine(this.peer, this.id);
  final ToyPeer peer;
  final String id;
  final DateTime startedAt = DateTime.now();
}

/// What a partner's panel knows about the toy it is steering.
class RemoteToyState {
  const RemoteToyState(this.raw);
  final Map<String, dynamic> raw;

  String? get toyName => (raw['toy'] as Map?)?['name'] as String?;
  int get battery => ((raw['toy'] as Map?)?['battery'] as num?)?.toInt() ?? -1;
  bool get toyConnected => raw['toy'] != null;
  bool get paused => raw['paused'] == true;
  int get cap => (raw['cap'] as num?)?.toInt() ?? 20;
  ToyActivity get activity =>
      ToyActivity.values.firstWhere((a) => a.name == raw['activity'], orElse: () => ToyActivity.idle);
  int get level => (raw['level'] as num?)?.toInt() ?? 0;
  ToyPattern? get pattern => ToyPatternInfo.fromName(raw['pattern'] as String?);
  int get strength => (raw['strength'] as num?)?.toInt() ?? 12;
  int? get bpm => (raw['bpm'] as num?)?.toInt();
  int get speed => (raw['speed'] as num?)?.toInt() ?? 0;
  double? get progress => (raw['progress'] as num?)?.toDouble();
  bool get youControl => raw['youControl'] == true;
  String? get controllerName => raw['controllerName'] as String?;
}

/// A partner's side: steering someone else's toy from a control panel.
class ToyRemoteController extends ChangeNotifier {
  ToyRemoteController({
    required this.partner,
    required String topic,
    HubConnector? connector,
    ToyPeerFactory? peers,
  }) : _peerFactory = peers {
    _room = ToyRoomSocket(
      topic: topic,
      role: 'ctl',
      onFrame: handleFrame,
      onConnectedChanged: (connected) {
        _connected = connected;
        if (connected) _send({'t': 'hello'});
        notifyListeners();
      },
      connector: connector,
    );
  }

  final PartnerContact partner;
  late final ToyRoomSocket _room;
  final ToyPeerFactory? _peerFactory;
  ToyPeerFactory? get _peers => _peerFactory ?? ToyPeer.factory;

  ToyPeer? _peer;
  String? _peerId;
  Timer? _peerRetry;
  Timer? _peerDeadline;
  Timer? _peerRenew;
  int _peerFailures = 0;

  /// The owner's device can't make direct lines; stay on the room.
  bool _directRefused = false;

  /// How long a new line has to open before the session gives up on it.
  static Duration lineDeadline = const Duration(seconds: 20);

  bool _connected = false;
  bool _ownerOnline = false;
  bool _denied = false;
  RemoteToyState? _state;
  Timer? _heartbeat;
  Timer? _levelTrailing;
  DateTime? _lastLevelSent;
  int? _pendingLevel;
  bool _disposed = false;

  bool get connected => _connected;
  bool get ownerOnline => _ownerOnline;
  bool get denied => _denied;
  RemoteToyState? get state => _state;

  /// Whether commands are going over a direct line rather than the room.
  bool get direct => _peer?.isOpen ?? false;

  /// Someone else has control right now.
  bool get busy {
    final s = _state;
    return s != null && !s.youControl && s.controllerName != null;
  }

  Future<void> open() async {
    await _room.open();
    _heartbeat = Timer.periodic(const Duration(seconds: 2), (_) => _send({'t': 'hb'}));
  }

  @visibleForTesting
  void handleFrame(String frame) {
    final presence = ToyPresence.parse(frame);
    if (presence != null) {
      _ownerOnline = presence.ownerOnline;
      if (!_ownerOnline) {
        _state = null;
        _dropLine();
      }
      if (_ownerOnline) _send({'t': 'hello'});
      _notify();
      return;
    }
    final body = _open(frame, partner.pairingSecret);
    if (body == null) return; // For another partner.
    if (body['t'] == 'rtc') {
      _onRtc(body);
      return;
    }
    if (body['t'] == 'denied') {
      _denied = true;
      _state = null;
      _dropLine();
    } else if (body['t'] == 'state') {
      _denied = false;
      _state = RemoteToyState(body);
      // Let in: time to ask for a direct line, if there isn't one.
      _maybeStartLine();
    }
    _notify();
  }

  // ---- Direct line --------------------------------------------------------

  void _maybeStartLine() {
    if (_disposed || _directRefused || _peer != null || _peerRetry != null) return;
    final make = _peers;
    if (make == null || !_ownerOnline) return;
    final id = _newLineId();
    final peer = make();
    _peer = peer;
    _peerId = id;
    var opened = false;
    peer.onSignal = (s) {
      if (!identical(_peer, peer)) return;
      if (!_sendSignal({...s, 't': 'rtc', 'id': id})) {
        // Too big for the room to carry: it would be dropped without a word,
        // and so would every retry. Stay on the room.
        _directRefused = true;
        _lineEnded(wasOpen: false);
      }
    };
    peer.onFrame = handleFrame;
    peer.onOpen = () {
      if (!identical(_peer, peer)) return;
      opened = true;
      _peerFailures = 0;
      _peerDeadline?.cancel();
      final expires = peer.expiresAt;
      if (expires != null) {
        // A fresh line before this one's TURN login runs out.
        final renewIn = expires.difference(DateTime.now()) - const Duration(minutes: 10);
        _peerRenew?.cancel();
        _peerRenew = Timer(renewIn.isNegative ? Duration.zero : renewIn, () {
          if (identical(_peer, peer)) _lineEnded(wasOpen: true);
        });
      }
      _notify();
    };
    peer.onClosed = () {
      // One that never opened failed, and is retried less and less often -
      // not at once, which asked for a TURN login every second.
      if (identical(_peer, peer)) _lineEnded(wasOpen: opened);
    };
    _peerDeadline?.cancel();
    _peerDeadline = Timer(lineDeadline, () {
      if (identical(_peer, peer) && !peer.isOpen) _lineEnded(wasOpen: false);
    });
    peer.start(offerer: true);
  }

  /// Sends a line signal through the room; false if it is too big to go.
  bool _sendSignal(Map<String, dynamic> body) {
    if (partner.pairingSecret.isEmpty) return false;
    final frame = _seal(body, partner.pairingSecret);
    if (frame.length > ToyRoomSocket.maxFrame) return false;
    _room.send(frame);
    return true;
  }

  void _onRtc(Map<String, dynamic> body) {
    final peer = _peer;
    if (peer == null || body['id'] != _peerId) return;
    if (body['k'] == 'end') {
      if (body['final'] == true) _directRefused = true;
      _lineEnded(wasOpen: peer.isOpen);
    } else {
      peer.handleSignal(body);
    }
  }

  /// A line closed or never opened: back on the room, and try again later.
  void _lineEnded({required bool wasOpen}) {
    final was = _peer;
    _dropLine();
    if (was == null || _disposed || _directRefused) return;
    if (!wasOpen) _peerFailures++;
    // A line that worked and then ended (renewal, a network change) is
    // replaced at once; one that never opened is retried less and less.
    final wait =
        wasOpen ? const Duration(seconds: 1) : Duration(seconds: min(300, 15 * (1 << min(_peerFailures - 1, 5))));
    _peerRetry = Timer(wait, () {
      _peerRetry = null;
      if (_state != null && !_denied) _maybeStartLine();
    });
    _notify();
  }

  void _dropLine() {
    _peerDeadline?.cancel();
    _peerRenew?.cancel();
    final peer = _peer;
    final id = _peerId;
    _peer = null;
    _peerId = null;
    if (peer == null) return;
    // The owner's side lets go of its end too.
    if (id != null) _send({'t': 'rtc', 'k': 'end', 'id': id}, viaRoom: true);
    peer.close();
  }

  static final Random _random = Random.secure();
  static String _newLineId() => List.generate(12, (_) => _random.nextInt(36).toRadixString(36)).join();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _send(Map<String, dynamic> body, {bool viaRoom = false}) {
    if (partner.pairingSecret.isEmpty) return;
    final frame = _seal(body, partner.pairingSecret);
    final peer = _peer;
    if (!viaRoom && peer != null && peer.isOpen) {
      peer.send(frame);
    } else {
      _room.send(frame);
    }
  }

  /// Sets a held level. Drags send at most ten a second; the last always goes.
  void setLevel(int level) {
    _pendingLevel = level.clamp(0, 20);
    final last = _lastLevelSent;
    final now = DateTime.now();
    if (last == null || now.difference(last) >= const Duration(milliseconds: 100)) {
      _flushLevel();
    } else {
      _levelTrailing ??= Timer(const Duration(milliseconds: 100) - now.difference(last), _flushLevel);
    }
  }

  void _flushLevel() {
    _levelTrailing?.cancel();
    _levelTrailing = null;
    final level = _pendingLevel;
    if (level == null) return;
    _pendingLevel = null;
    _lastLevelSent = DateTime.now();
    _send({'t': 'level', 'v': level});
  }

  void playPattern(ToyPattern pattern, int strength) => _send({'t': 'pattern', 'p': pattern.name, 'v': strength});

  void setStrength(int strength) => _send({'t': 'strength', 'v': strength});

  void startMetronome(CadenceConfig config, {int seconds = 0, required int strength}) =>
      _send({'t': 'metronome', 'cfg': config.toJson(), 'secs': seconds, 'v': strength});

  void updateMetronome(CadenceConfig config) => _send({'t': 'metronomeUpdate', 'cfg': config.toJson()});

  void stop() {
    _levelTrailing?.cancel();
    _levelTrailing = null;
    _pendingLevel = null;
    _send({'t': 'stop'});
  }

  Future<void> close() async {
    _heartbeat?.cancel();
    _levelTrailing?.cancel();
    _peerRetry?.cancel();
    _peerRetry = null;
    // Both ways: a line closing right behind it could lose it.
    if (direct) _send({'t': 'bye'});
    _send({'t': 'bye'}, viaRoom: true);
    _directRefused = true;
    final peer = _peer;
    _peer = null;
    _peerId = null;
    _peerDeadline?.cancel();
    _peerRenew?.cancel();
    await peer?.close();
    await _room.close();
  }

  @override
  void dispose() {
    _disposed = true;
    _heartbeat?.cancel();
    _levelTrailing?.cancel();
    _peerRetry?.cancel();
    _peerDeadline?.cancel();
    _peerRenew?.cancel();
    _peer?.close();
    _peer = null;
    super.dispose();
  }
}
