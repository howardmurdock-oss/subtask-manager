import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/core/security/proof_crypto.dart';
import 'package:orders_app/models/active_order.dart';
import 'package:orders_app/models/chastity_timer.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/services/chastity_timer_service.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/public_order_bridge.dart';
import 'package:orders_app/services/storage_service.dart';

/// Orders the public sends from a timer's page, on the player's side.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('proof for the sender', () {
    // The page's side, done here the same way: ECDH, HKDF, AES-GCM.
    Uint8List open(String envelope, ECPrivateKey recipient) {
      final env = jsonDecode(envelope) as Map<String, dynamic>;
      final params = ECDomainParameters('secp256r1');
      final epk = ECPublicKey(params.curve.decodePoint(base64.decode(env['epk'] as String)), params);
      final shared = (ECDHBasicAgreement()..init(recipient)).calculateAgreement(epk);
      final secret = Uint8List(32);
      var v = shared;
      for (var i = 31; i >= 0; i--) {
        secret[i] = (v & BigInt.from(0xff)).toInt();
        v = v >> 8;
      }
      final key = (HKDFKeyDerivator(SHA256Digest())
            ..init(HkdfParameters(secret, 32, Uint8List(32), Uint8List.fromList(utf8.encode(ProofCrypto.info)))))
          .process(Uint8List(0));
      final gcm = GCMBlockCipher(AESEngine())
        ..init(false, AEADParameters(KeyParameter(key), 128, base64.decode(env['iv'] as String), Uint8List(0)));
      return gcm.process(base64.decode(env['ct'] as String));
    }

    AsymmetricKeyPair recipient([int seed = 7]) {
      final params = ECDomainParameters('secp256r1');
      final random = FortunaRandom()..seed(KeyParameter(Uint8List.fromList(List.generate(32, (i) => i * seed + 1))));
      return (ECKeyGenerator()..init(ParametersWithRandom(ECKeyGeneratorParameters(params), random))).generateKeyPair();
    }

    test('only the matching key opens it, and it says what it is', () {
      final pair = recipient();
      final pub = base64.encode((pair.publicKey as ECPublicKey).Q!.getEncoded(false));
      final envelope = ProofCrypto.encrypt(pub, Uint8List.fromList(utf8.encode('locked')), 'text/plain');
      expect(jsonDecode(envelope)['mime'], 'text/plain');
      expect(utf8.decode(open(envelope, pair.privateKey as ECPrivateKey)), 'locked');
      expect(envelope.contains('locked'), isFalse, reason: 'nothing readable on the way');
      expect(() => open(envelope, recipient(11).privateKey as ECPrivateKey), throwsA(anything),
          reason: "anyone else's key fails the integrity check");
    });

    test('a fresh key each time: the same proof never looks the same twice', () {
      final pair = recipient();
      final pub = base64.encode((pair.publicKey as ECPublicKey).Q!.getEncoded(false));
      final a = jsonDecode(ProofCrypto.encrypt(pub, Uint8List.fromList([1, 2, 3]), 'image/jpeg'));
      final b = jsonDecode(ProofCrypto.encrypt(pub, Uint8List.fromList([1, 2, 3]), 'image/jpeg'));
      expect(a['epk'], isNot(b['epk']));
      expect(a['ct'], isNot(b['ct']));
    });
  });

  test('an order from the library keeps what the page and the player need', () {
    final item = OrderItem(
      id: 'abc/123 !',
      title: 'Plank',
      description: 'Two minutes.',
      durationType: DurationType.deadlineCountdown,
      durationMinutes: 30,
      verificationType: VerificationType.photoProof,
      rewardTokens: 5,
      penaltyTokens: 2,
    );
    final def = PublicOrderDef.fromOrder(item);
    expect(def.id, 'abc123', reason: 'only characters the Worker accepts');
    final back = PublicOrderDef.fromJson(def.toJson()).toOrder(id: 'x');
    expect(back.title, 'Plank');
    expect(back.durationMinutes, 30);
    expect(back.verificationType, VerificationType.photoProof);
    expect(back.rewardTokens, 5);
    expect(back.allowRandomDraw, isFalse, reason: 'never drawn at random later');

    final settings = PublicOrdersSettings(enabled: true, orders: [def], proofTo: PublicProofTo.issuer);
    final again = PublicOrdersSettings.fromJson(settings.toJson());
    expect(again.proofTo, PublicProofTo.issuer);
    expect(again.maxQueued, isNull);
    expect(again.orders.single.title, 'Plank');
  });

  group('the bridge', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    late OrderEngine engine;
    late ChastityTimerService timers;
    late PublicOrderBridge bridge;
    late List<({String path, Object? body})> calls;
    late Map<String, dynamic> orders;

    Map<String, dynamic> def({String verification = 'honorCheck'}) =>
        {'id': 'plank', 'title': 'Plank', 'verification': verification, 'rewardTokens': 5, 'penaltyTokens': 2};

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      calls = [];
      orders = {
        'enabled': true,
        'proofTo': 'director',
        'active': {'no': 1, 'def': def(), 'deliveredAt': now, 'dueAt': now + 3600 * 1000},
        'waiting': 0,
        'skipsLeft': 2,
        'feed': [
          {'no': 1, 'title': 'Plank', 'status': 'active', 'at': now},
        ],
      };
      ChastityTimerService.request = (method, url, {key, body}) async {
        calls.add((path: url.path, body: body));
        return TimerApiResponse(200, {
          'id': 't1',
          'role': 'player',
          'manager': true,
          'status': 'running',
          'startAt': now,
          'endAt': now + 3600 * 1000,
          'config': {'baseSeconds': 3600},
          'history': const [],
          'now': now,
          'orders': orders,
        });
      };
      engine = OrderEngine(storage: StorageService());
      await engine.init();
      timers = ChastityTimerService();
      await timers.load();
      bridge = PublicOrderBridge(engine: engine, timers: timers);
      await bridge.start();
    });

    tearDown(() => bridge.dispose());

    ActiveOrder? delivered() => engine.activeOrders.where((o) => o.id == 'public-t1-1').firstOrNull;
    Iterable<Map> reports() => calls.where((c) => c.path.endsWith('/order-result')).map((c) => c.body as Map);

    test("a delivered order joins the player's list, once", () async {
      await timers.addShared(id: 't1', role: TimerRole.player, key: 'P');
      await pumpEventQueue();
      await timers.refresh('t1');
      await pumpEventQueue();
      expect(delivered()?.order.title, 'Plank');
      expect(engine.activeOrders.where((o) => o.id == 'public-t1-1').length, 1);
      expect(delivered()!.assignedByPartnerName, 'the public');
    });

    test('done: reported, and its tokens paid as for any order', () async {
      await timers.addShared(id: 't1', role: TimerRole.player, key: 'P');
      await pumpEventQueue();
      final before = engine.stats.tokens;
      engine.completeOrder('public-t1-1');
      await pumpEventQueue();
      expect(reports().single, {'no': 1, 'result': 'completed'});
      expect(engine.stats.tokens, before + 5);
    });

    test('failed: reported as failed', () async {
      await timers.addShared(id: 't1', role: TimerRole.player, key: 'P');
      await pumpEventQueue();
      engine.failOrder('public-t1-1');
      await pumpEventQueue();
      expect(reports().single['result'], 'failed');
    });

    test('proof for the sender is sent encrypted to their key', () async {
      final params = ECDomainParameters('secp256r1');
      final pair = (ECKeyGenerator()
            ..init(ParametersWithRandom(ECKeyGeneratorParameters(params),
                FortunaRandom()..seed(KeyParameter(Uint8List.fromList(List.filled(32, 9)))))))
          .generateKeyPair();
      orders = {
        ...orders,
        'proofTo': 'issuer',
        'active': {
          'no': 1,
          'def': def(verification: 'photoProof'),
          'deliveredAt': now,
          'issuerKey': base64.encode((pair.publicKey as ECPublicKey).Q!.getEncoded(false)),
        },
      };
      await timers.addShared(id: 't1', role: TimerRole.player, key: 'P');
      await pumpEventQueue();
      final order = delivered()!;
      expect(bridge.destinationOf(order)?.to, PublicProofDestination.issuer);
      expect(await bridge.submit(order, imageBase64: base64.encode([0xff, 0xd8, 0xff, 1, 2, 3])), isNull);
      final sent = reports().single;
      expect(sent['result'], 'submitted', reason: 'a photo for its sender waits for them to approve it');
      final envelope = jsonDecode(sent['proof'] as String);
      expect(envelope['mime'], 'image/jpeg');
      expect(envelope['epk'], isNotNull);
      final before = engine.stats.tokens;
      expect(engine.activeOrders.firstWhere((o) => o.id == 'public-t1-1').status, OrderStatus.underReview);
      expect(engine.stats.tokens, before, reason: 'no tokens until it is approved');

      // They approve it: done, and its tokens paid.
      orders = {...orders, 'active': null, 'feed': [{'no': 1, 'title': 'Plank', 'status': 'completed', 'at': now}]};
      await timers.refresh('t1');
      await pumpEventQueue();
      expect(engine.activeOrders.firstWhere((o) => o.id == 'public-t1-1').status, OrderStatus.completed);
      expect(engine.stats.tokens, before + 5);
    });

    test('a photo its sender rejects counts as failed', () async {
      final params = ECDomainParameters('secp256r1');
      final pair = (ECKeyGenerator()
            ..init(ParametersWithRandom(ECKeyGeneratorParameters(params),
                FortunaRandom()..seed(KeyParameter(Uint8List.fromList(List.filled(32, 3)))))))
          .generateKeyPair();
      orders = {
        ...orders,
        'proofTo': 'issuer',
        'active': {
          'no': 1,
          'def': def(verification: 'photoProof'),
          'deliveredAt': now,
          'issuerKey': base64.encode((pair.publicKey as ECPublicKey).Q!.getEncoded(false)),
        },
      };
      await timers.addShared(id: 't1', role: TimerRole.player, key: 'P');
      await pumpEventQueue();
      await bridge.submit(delivered()!, imageBase64: base64.encode([0xff, 0xd8, 0xff, 9]));
      orders = {...orders, 'active': null, 'feed': [{'no': 1, 'title': 'Plank', 'status': 'failed', 'at': now}]};
      await timers.refresh('t1');
      await pumpEventQueue();
      final order = engine.activeOrders.firstWhere((o) => o.id == 'public-t1-1');
      expect(order.status, OrderStatus.failed);
      expect(order.directorNote, 'Rejected by whoever sent it');
    });

    test('proof for the director waits for their review', () async {
      await timers.addShared(id: 't1', role: TimerRole.player, key: 'P', partnerCode: 'DIR123', partnerName: 'Sir');
      await pumpEventQueue();
      final order = delivered()!;
      expect(bridge.destinationOf(order)?.to, PublicProofDestination.director);
      expect(bridge.destinationOf(order)?.directorName, 'Sir');
      engine.submitOrCompleteOrder(order.id, proofImageBase64: 'abc');
      await pumpEventQueue();
      expect(reports().map((r) => r['result']), ['submitted'],
          reason: 'held as being checked, so it does not run out of time while they look');

      // The director approves: done, and the Worker told.
      engine.approveProof(order.id);
      await pumpEventQueue();
      expect(reports().map((r) => r['result']), ['submitted', 'completed']);
    });

    test('approved for want of a check: a late approval does not pay twice', () async {
      await timers.addShared(id: 't1', role: TimerRole.player, key: 'P', partnerCode: 'DIR123', partnerName: 'Sir');
      await pumpEventQueue();
      final before = engine.stats.tokens;
      engine.submitOrCompleteOrder(delivered()!.id, proofImageBase64: 'abc');
      await pumpEventQueue();
      orders = {...orders, 'active': null, 'feed': [{'no': 1, 'title': 'Plank', 'status': 'completed', 'at': now, 'auto': true}]};
      await timers.refresh('t1');
      await pumpEventQueue();
      expect(engine.stats.tokens, before + 5);
      engine.approveProof('public-t1-1');
      expect(engine.stats.tokens, before + 5, reason: 'already settled');
    });

    test('a skip: told to the Worker, and gone without a penalty', () async {
      await timers.addShared(id: 't1', role: TimerRole.player, key: 'P');
      await pumpEventQueue();
      final before = engine.stats.tokens;
      expect(await bridge.skip('public-t1-1'), isNull);
      expect(calls.where((c) => c.path.endsWith('/order-skip')).length, 1);
      expect(delivered(), isNull);
      expect(engine.stats.tokens, before);
    });

    test('one that ran out of time on the Worker fails here too', () async {
      await timers.addShared(id: 't1', role: TimerRole.player, key: 'P');
      await pumpEventQueue();
      orders = {
        ...orders,
        'active': null,
        'feed': [
          {'no': 1, 'title': 'Plank', 'status': 'expired', 'at': now},
        ],
      };
      await timers.refresh('t1');
      await pumpEventQueue();
      expect(engine.activeOrders.firstWhere((o) => o.id == 'public-t1-1').status, OrderStatus.failed);
      expect(reports(), isEmpty, reason: 'nothing to tell the Worker it does not know');
    });
  });
}
