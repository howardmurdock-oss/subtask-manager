import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/services/toy/toy_models.dart';
import 'package:orders_app/services/toy/toy_patterns.dart';
import 'package:orders_app/services/toy/toy_peer.dart';
import 'package:orders_app/services/toy/toy_player.dart';
import 'package:orders_app/services/toy/toy_remote.dart';
import 'package:orders_app/services/toy/toy_service.dart';
import 'package:orders_app/services/worker_socket_service.dart' show HubChannel;
import 'package:shared_preferences/shared_preferences.dart';

/// Records what would have gone to the toy.
class _Recorder implements ToyOutput {
  final List<int> speeds = [];
  int stops = 0;
  @override
  void setSpeed(int speed) => speeds.add(speed);
  @override
  void stop() => stops++;
}

/// The Worker's toy room, in memory: partner frames to the owner, owner
/// frames to every partner, and presence when anyone comes or goes.
class _FakeRoom {
  final List<_FakeChannel> owners = [];
  final List<_FakeChannel> ctls = [];

  /// Frames relayed, pings aside: what the Worker would be billed for.
  int relayed = 0;

  Future<HubChannel> connect(Uri url) async {
    final ch = _FakeChannel(this, url.queryParameters['role']!);
    (ch.role == 'owner' ? owners : ctls).add(ch);
    _announce();
    return ch;
  }

  void relay(_FakeChannel from, String data) {
    if (data == 'ping') return from.deliver('pong');
    relayed++;
    for (final to in from.role == 'owner' ? ctls : owners) {
      to.deliver(data);
    }
  }

  void leave(_FakeChannel ch) {
    owners.remove(ch);
    ctls.remove(ch);
    _announce();
  }

  void _announce() {
    final frame = jsonEncode({'sys': 'presence', 'owner': owners.isNotEmpty, 'controllers': ctls.length});
    for (final ch in [...owners, ...ctls]) {
      ch.deliver(frame);
    }
  }
}

class _FakeChannel implements HubChannel {
  _FakeChannel(this.room, this.role);
  final _FakeRoom room;
  final String role;
  final _ctrl = StreamController<dynamic>();

  @override
  Stream<dynamic> get stream => _ctrl.stream;

  @override
  void send(String data) => room.relay(this, data);

  void deliver(String data) {
    if (!_ctrl.isClosed) _ctrl.add(data);
  }

  @override
  Future<void> close() async {
    room.leave(this);
    await _ctrl.close();
  }
}

/// Direct lines in memory: an offer finds its answerer by name, and once
/// answered both ends open and pass frames straight to each other.
class _FakeLines {
  final Map<String, _FakeLine> _offered = {};
  final List<_FakeLine> made = [];
  int _n = 0;

  /// When false, offers are answered but lines never open.
  bool canOpen = true;

  /// Offers as big as flutter_webrtc's default audio+video ones were.
  bool bigOffers = false;

  /// Lines fail as they start, as when no TURN login can be had.
  bool failOnStart = false;

  ToyPeer make() {
    final line = _FakeLine(this);
    made.add(line);
    return line;
  }

  List<_FakeLine> get open => made.where((l) => l.isOpen).toList();
}

class _FakeLine extends ToyPeer {
  _FakeLine(this.lines);
  final _FakeLines lines;
  _FakeLine? other;
  bool _open = false;
  bool closed = false;

  @override
  bool get isOpen => _open;
  @override
  DateTime? get expiresAt => null;

  @override
  Future<void> start({required bool offerer}) async {
    if (!offerer) return;
    if (lines.failOnStart) {
      closed = true;
      scheduleMicrotask(() => onClosed?.call());
      return;
    }
    final name = 'offer-${lines._n++}';
    lines._offered[name] = this;
    onSignal?.call({'k': 'offer', 'sdp': name, if (lines.bigOffers) 'pad': 'x' * 6400});
    onSignal?.call({'k': 'cand', 'c': 'candidate:relay', 'mid': '0', 'idx': 0});
  }

  @override
  void handleSignal(Map<String, dynamic> signal) {
    if (closed) return;
    if (signal['k'] == 'offer') {
      final offerer = lines._offered.remove(signal['sdp']);
      if (offerer == null) return;
      other = offerer;
      offerer.other = this;
      onSignal?.call({'k': 'answer', 'sdp': 'answer'});
    } else if (signal['k'] == 'answer' && lines.canOpen) {
      final o = other;
      if (o == null || o.closed) return;
      _open = true;
      o._open = true;
      onOpen?.call();
      o.onOpen?.call();
    }
  }

  @override
  void send(String frame) {
    final o = other;
    if (_open && o != null && !o.closed) scheduleMicrotask(() => o.onFrame?.call(frame));
  }

  /// The network dropping it: both ends hear.
  void drop() {
    for (final end in [this, other]) {
      if (end == null || end.closed) continue;
      end.closed = true;
      end._open = false;
      end.onClosed?.call();
    }
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    _open = false;
    final o = other;
    if (o != null && !o.closed) {
      o.closed = true;
      o._open = false;
      o.onClosed?.call();
    }
  }
}

class _Ctx implements ToyRemoteContext {
  _Ctx(this.partners);
  @override
  final List<PartnerContact> partners;
  final List<String> statuses = [];

  @override
  String get myCode => 'OWNER1';
  @override
  String get myName => 'Owner';
  @override
  Future<void> sendToyStatus(PartnerContact partner, {required bool online, String? toyName}) async =>
      statuses.add('${partner.displayName}:${online ? 'online' : 'offline'}');
  @override
  String topicFor(String code) => 'topic-for-$code';
}

Future<void> _settle([int ms = 30]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  group('patterns', () {
    test('heartbeat is two beats, the second softer, then a rest', () {
      expect(ToyPattern.heartbeat.levelAt(const Duration(milliseconds: 50)), 1);
      expect(ToyPattern.heartbeat.levelAt(const Duration(milliseconds: 200)), 0);
      expect(ToyPattern.heartbeat.levelAt(const Duration(milliseconds: 300)), 0.8);
      expect(ToyPattern.heartbeat.levelAt(const Duration(milliseconds: 800)), 0);
      expect(ToyPattern.heartbeat.levelAt(const Duration(milliseconds: 1250)), 1, reason: 'and again');
    });

    test('there is no plain pulse pattern: the metronome does that', () {
      expect(ToyPatternInfo.fromName('pulse'), isNull);
    });

    test('escalate builds for 30 seconds, then holds at full', () {
      final early = ToyPattern.escalate.levelAt(const Duration(seconds: 5));
      final later = ToyPattern.escalate.levelAt(const Duration(seconds: 20));
      expect(later, greaterThan(early));
      expect(ToyPattern.escalate.levelAt(const Duration(seconds: 30)), 1);
      expect(ToyPattern.escalate.levelAt(const Duration(minutes: 5)), 1);
    });

    test('speeds scale to the strength chosen, and still means 0', () {
      expect(ToyPattern.heartbeat.speedAt(Duration.zero, 14), 14);
      expect(ToyPattern.heartbeat.speedAt(const Duration(milliseconds: 200), 14), 0);
      expect(ToyPattern.staircase.speedAt(Duration.zero, 20), 5);
      expect(ToyPattern.staircase.speedAt(const Duration(seconds: 13), 20), 20);
      for (final p in ToyPattern.values) {
        for (var ms = 0; ms < 40000; ms += 250) {
          expect(p.speedAt(Duration(milliseconds: ms), 8, seed: 3), inInclusiveRange(0, 8));
        }
      }
    });

    test('tease is the same within one run and differs between runs', () {
      List<double> run(int seed) =>
          [for (var s = 0; s < 40; s++) ToyPattern.tease.levelAt(Duration(milliseconds: s * 1500), seed: seed)];
      expect(run(1), run(1));
      expect(run(1), isNot(run(2)));
      expect(run(1).where((l) => l > 0), isNotEmpty);
    });
  });

  group('player', () {
    test('a level holds; 0 stops', () {
      final out = _Recorder();
      final player = ToyPlayer(output: out);
      player.setLevel(9);
      expect(out.speeds.last, 9);
      expect(player.activity, ToyActivity.level);
      player.setLevel(0);
      expect(player.activity, ToyActivity.idle);
      expect(out.stops, 1);
    });

    test('a pattern plays on its own clock until stopped', () async {
      final out = _Recorder();
      final player = ToyPlayer(output: out, patternTick: const Duration(milliseconds: 20));
      player.playPattern(ToyPattern.heartbeat, 10);
      await _settle(120);
      expect(out.speeds, isNotEmpty);
      expect(out.speeds.every((s) => s == 0 || s == 8 || s == 10), isTrue);
      player.stop();
      final sent = out.speeds.length;
      await _settle(80);
      expect(out.speeds.length, sent, reason: 'nothing more once stopped');
      expect(player.activity, ToyActivity.idle);
    });
  });

  group('live control', () {
    const sharedA = 'secret-shared-with-alex-000000';
    const sharedB = 'secret-shared-with-blair-00000';
    const sharedC = 'secret-shared-with-casey-00000';

    // The owner's view of each partner, and each partner's view of the owner:
    // the two hold the same secret from pairing.
    final alex = PartnerContact(displayName: 'Alex', pairingCode: 'ALEX01', pairingSecret: sharedA);
    final blair = PartnerContact(displayName: 'Blair', pairingCode: 'BLAIR1', pairingSecret: sharedB);
    final casey = PartnerContact(displayName: 'Casey', pairingCode: 'CASEY1', pairingSecret: sharedC);
    PartnerContact ownerAs(String secret) =>
        PartnerContact(displayName: 'Owner', pairingCode: 'OWNER1', pairingSecret: secret);

    late _FakeRoom room;
    late _Ctx ctx;
    late ToyRemoteHost host;
    late ToyPlayer player;
    final toy = ToyService.instance;
    final controllers = <ToyRemoteController>[];

    Future<ToyRemoteController> join(String secret) async {
      final c = ToyRemoteController(partner: ownerAs(secret), topic: 'topic-for-OWNER1', connector: room.connect);
      controllers.add(c);
      await c.open();
      await _settle(350);
      return c;
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      room = _FakeRoom();
      ctx = _Ctx([alex, blair, casey]);
      player = ToyPlayer(patternTick: const Duration(milliseconds: 20));
      toy.outputCap = null;
      toy.debugSetConnected(const ConnectedToyInfo(id: 'x', name: 'Test Toy', batteryLevel: 80));
      host = ToyRemoteHost(player: player, connector: room.connect, quietLimit: const Duration(milliseconds: 900));
      await host.start(ctx);
    });

    tearDown(() async {
      for (final c in controllers) {
        await c.close();
        c.dispose();
      }
      controllers.clear();
      await host.stopService();
      player.stop();
      toy.outputCap = null;
      toy.debugSetConnected(null);
    });

    test('nobody allowed: the toy stays off the network', () async {
      await _settle();
      expect(room.owners, isEmpty);
      expect(ctx.statuses, isEmpty);
    });

    test('allowing a partner tells them, and they can drive the toy', () async {
      await host.setAllowed(alex, true);
      expect(ctx.statuses, ['Alex:online']);
      expect(room.owners, hasLength(1));

      final a = await join(sharedA);
      expect(a.ownerOnline, isTrue);
      expect(a.state?.toyName, 'Test Toy');
      expect(a.state?.battery, 80);

      a.setLevel(9);
      await _settle(100);
      expect(toy.currentSpeed, 9);
      expect(host.controller?.displayName, 'Alex');

      await _settle(300);
      expect(a.state?.youControl, isTrue);
      expect(a.state?.level, 9);

      a.playPattern(ToyPattern.heartbeat, 7);
      await _settle(100);
      expect(player.activity, ToyActivity.pattern);
      expect(player.strength, 7);

      a.stop();
      await _settle(100);
      expect(player.activity, ToyActivity.idle);
      expect(toy.currentSpeed, 0);
    });

    test("a partner who isn't allowed is told so, and nothing moves", () async {
      await host.setAllowed(alex, true);
      final b = await join(sharedB);
      expect(b.denied, isTrue);
      b.setLevel(15);
      await _settle(100);
      expect(toy.currentSpeed, 0);
      expect(host.controller, isNull);
    });

    test("the owner's limit caps whatever a partner sends", () async {
      await host.setAllowed(alex, true);
      await host.setCap(5);
      final a = await join(sharedA);
      expect(a.state?.cap, 5);
      a.setLevel(18);
      await _settle(100);
      expect(toy.currentSpeed, 5);
    });

    test('one partner in control at a time', () async {
      await host.setAllowed(alex, true);
      await host.setAllowed(casey, true);
      final a = await join(sharedA);
      final c = await join(sharedC);
      a.setLevel(6);
      await _settle(100);
      c.setLevel(17);
      await _settle(350);
      expect(toy.currentSpeed, 6);
      expect(host.controller?.displayName, 'Alex');
      expect(c.busy, isTrue);
      expect(c.state?.controllerName, 'Alex');
    });

    test('the toy stops when the partner in control goes quiet', () async {
      await host.setAllowed(alex, true);
      final a = await join(sharedA);
      a.setLevel(10);
      await _settle(100);
      expect(toy.currentSpeed, 10);
      // The panel dies without saying goodbye (a phone losing signal): its
      // heartbeats stop, and the test host gives up after 0.9s of silence.
      controllers.remove(a);
      a.dispose();
      await _settle(2200);
      expect(host.controller, isNull);
      expect(toy.currentSpeed, 0);
    });

    test('leaving the panel stops the toy', () async {
      await host.setAllowed(alex, true);
      final a = await join(sharedA);
      a.setLevel(10);
      await _settle(100);
      await a.close();
      controllers.remove(a);
      a.dispose();
      await _settle(100);
      expect(toy.currentSpeed, 0);
      expect(host.controller, isNull);
    });

    test('pausing, Stop, and taking back permission', () async {
      await host.setAllowed(alex, true);
      final a = await join(sharedA);
      a.setLevel(8);
      await _settle(100);

      host.stopNow();
      expect(toy.currentSpeed, 0);
      expect(host.controller, isNull);

      await host.setPaused(true);
      a.setLevel(12);
      await _settle(350);
      expect(toy.currentSpeed, 0);
      expect(a.state?.paused, isTrue);

      await host.setPaused(false);
      a.setLevel(12);
      await _settle(100);
      expect(toy.currentSpeed, 12);

      await host.setAllowed(alex, false);
      await _settle(100);
      expect(toy.currentSpeed, 0, reason: 'un-allowing the partner in control stops the toy');
      expect(a.denied, isTrue);
      expect(ctx.statuses.last, 'Alex:offline');
    });

    test('disconnecting the toy takes it offline for partners', () async {
      await host.setAllowed(alex, true);
      final a = await join(sharedA);
      toy.debugSetConnected(null);
      await _settle(100);
      expect(ctx.statuses.last, 'Alex:offline');
      expect(room.owners, isEmpty);
      expect(a.ownerOnline, isFalse);
    });
  });

  group('direct line', () {
    const sharedA = 'secret-shared-with-alex-000000';
    const sharedB = 'secret-shared-with-blair-00000';
    final alex = PartnerContact(displayName: 'Alex', pairingCode: 'ALEX01', pairingSecret: sharedA);
    final blair = PartnerContact(displayName: 'Blair', pairingCode: 'BLAIR1', pairingSecret: sharedB);
    PartnerContact ownerAs(String secret) =>
        PartnerContact(displayName: 'Owner', pairingCode: 'OWNER1', pairingSecret: secret);

    late _FakeRoom room;
    late _FakeLines lines;
    late ToyRemoteHost host;
    late ToyPlayer player;
    final toy = ToyService.instance;
    final controllers = <ToyRemoteController>[];

    Future<ToyRemoteController> join(String secret) async {
      final c = ToyRemoteController(
        partner: ownerAs(secret),
        topic: 'topic-for-OWNER1',
        connector: room.connect,
        peers: lines.make,
      );
      controllers.add(c);
      await c.open();
      await _settle(350);
      return c;
    }

    Future<void> startHost({bool ownerCanMakeLines = true}) async {
      host = ToyRemoteHost(
        player: player,
        connector: room.connect,
        peers: ownerCanMakeLines ? lines.make : null,
        // Longer than the panel's 2s heartbeat, as in the app.
        quietLimit: const Duration(seconds: 3),
      );
      await host.start(_Ctx([alex, blair]));
      await host.setAllowed(alex, true);
    }

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      room = _FakeRoom();
      lines = _FakeLines();
      player = ToyPlayer(patternTick: const Duration(milliseconds: 20));
      toy.outputCap = null;
      toy.debugSetConnected(const ConnectedToyInfo(id: 'x', name: 'Test Toy', batteryLevel: 80));
    });

    tearDown(() async {
      for (final c in controllers) {
        await c.close();
        c.dispose();
      }
      controllers.clear();
      await host.stopService();
      player.stop();
      toy.outputCap = null;
      toy.debugSetConnected(null);
      ToyRemoteController.lineDeadline = const Duration(seconds: 20);
    });

    test('once the line opens, the session leaves the room', () async {
      await startHost();
      final a = await join(sharedA);
      expect(a.direct, isTrue);
      expect(host.isDirect(alex), isTrue);

      final before = room.relayed;
      a.setLevel(11);
      await _settle(400);
      expect(toy.currentSpeed, 11);
      expect(a.state?.level, 11, reason: 'state comes back over the line too');
      a.playPattern(ToyPattern.wave, 8);
      await _settle(2300); // past a heartbeat
      expect(player.activity, ToyActivity.pattern);
      expect(host.controller?.displayName, 'Alex', reason: 'heartbeats arrive over the line');
      expect(room.relayed, before, reason: 'nothing more through the Worker');
    });

    test('a dropped line falls back to the room at once, then reconnects', () async {
      await startHost();
      final a = await join(sharedA);
      expect(a.direct, isTrue);

      lines.open.first.drop();
      expect(a.direct, isFalse);
      a.setLevel(6);
      await _settle(100);
      expect(toy.currentSpeed, 6, reason: 'carried by the room meanwhile');

      await _settle(1300);
      expect(a.direct, isTrue, reason: 'a line that worked is replaced straight away');
      expect(host.isDirect(alex), isTrue);
      a.setLevel(3);
      await _settle(100);
      expect(toy.currentSpeed, 3);
    });

    test("a line that won't open is given up on, and the room carries on", () async {
      ToyRemoteController.lineDeadline = const Duration(milliseconds: 300);
      lines.canOpen = false;
      await startHost();
      final a = await join(sharedA);
      await _settle(400);
      expect(a.direct, isFalse);
      expect(host.isDirect(alex), isFalse);
      expect(lines.made.every((l) => l.closed), isTrue, reason: 'both ends let go');
      a.setLevel(8);
      await _settle(100);
      expect(toy.currentSpeed, 8);
    });

    test("an owner who can't make lines keeps the session on the room", () async {
      await startHost(ownerCanMakeLines: false);
      final a = await join(sharedA);
      expect(a.direct, isFalse);
      expect(lines.made, hasLength(1));
      await _settle(1500);
      expect(lines.made, hasLength(1), reason: 'told not to, the panel stops asking');
      a.setLevel(5);
      await _settle(100);
      expect(toy.currentSpeed, 5);
    });

    test('only an allowed partner gets a line, and losing permission ends it', () async {
      await startHost();
      final b = await join(sharedB);
      expect(b.denied, isTrue);
      expect(lines.made, isEmpty, reason: 'no line for someone not let in');

      final a = await join(sharedA);
      expect(a.direct, isTrue);
      await host.setAllowed(alex, false);
      await _settle(100);
      expect(a.denied, isTrue);
      expect(a.direct, isFalse);
      expect(lines.open, isEmpty);
    });

    test('a line signal too big for the room: stay on the room, and stop asking', () async {
      lines.bigOffers = true;
      await startHost();
      final a = await join(sharedA);
      await _settle(1500);
      expect(a.direct, isFalse);
      expect(lines.made, hasLength(1), reason: 'every retry would be dropped the same way');
      a.setLevel(9);
      await _settle(100);
      expect(toy.currentSpeed, 9);
    });

    test("a line that fails before opening isn't retried every second", () async {
      lines.failOnStart = true;
      await startHost();
      final a = await join(sharedA);
      await _settle(2500);
      expect(a.direct, isFalse);
      expect(lines.made, hasLength(1), reason: 'the next try waits 15 seconds');
      a.setLevel(4);
      await _settle(100);
      expect(toy.currentSpeed, 4);
    });

    test('leaving the panel ends the line and stops the toy', () async {
      await startHost();
      final a = await join(sharedA);
      a.setLevel(10);
      await _settle(100);
      expect(toy.currentSpeed, 10);
      await a.close();
      controllers.remove(a);
      a.dispose();
      await _settle(100);
      expect(toy.currentSpeed, 0);
      expect(host.controller, isNull);
      expect(host.isDirect(alex), isFalse);
    });
  });
}
