import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/services/toy/toy_models.dart';
import 'package:orders_app/services/toy/toy_patterns.dart';
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

  Future<HubChannel> connect(Uri url) async {
    final ch = _FakeChannel(this, url.queryParameters['role']!);
    (ch.role == 'owner' ? owners : ctls).add(ch);
    _announce();
    return ch;
  }

  void relay(_FakeChannel from, String data) {
    if (data == 'ping') return from.deliver('pong');
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
    test('pulse alternates every half second', () {
      expect(ToyPattern.pulse.levelAt(const Duration(milliseconds: 100)), 1);
      expect(ToyPattern.pulse.levelAt(const Duration(milliseconds: 600)), 0);
      expect(ToyPattern.pulse.levelAt(const Duration(milliseconds: 1100)), 1);
    });

    test('escalate builds for 30 seconds, then holds at full', () {
      final early = ToyPattern.escalate.levelAt(const Duration(seconds: 5));
      final later = ToyPattern.escalate.levelAt(const Duration(seconds: 20));
      expect(later, greaterThan(early));
      expect(ToyPattern.escalate.levelAt(const Duration(seconds: 30)), 1);
      expect(ToyPattern.escalate.levelAt(const Duration(minutes: 5)), 1);
    });

    test('speeds scale to the strength chosen, and still means 0', () {
      expect(ToyPattern.pulse.speedAt(Duration.zero, 14), 14);
      expect(ToyPattern.pulse.speedAt(const Duration(milliseconds: 600), 14), 0);
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
      player.playPattern(ToyPattern.pulse, 10);
      await _settle(120);
      expect(out.speeds, isNotEmpty);
      expect(out.speeds.every((s) => s == 0 || s == 10), isTrue);
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

      a.playPattern(ToyPattern.pulse, 7);
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
}
