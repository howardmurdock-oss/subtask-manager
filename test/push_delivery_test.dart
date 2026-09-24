import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/core/security/encryption_helper.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/push_service.dart';
import 'package:orders_app/services/sync_service.dart';

/// Firebase delivers the same encrypted payload the relay carries, so a pushed
/// directive must land through exactly the same decode-and-dispatch path — not
/// a parallel one that would need its own copy of addressing, dedup and the
/// occurrence ledger.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const myCode = 'PLAYER1';
  const mySecret = 'SHARED_SECRET';

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<(SyncService, OrderEngine)> player() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pairing_code', myCode);
    await prefs.setString('pairing_secret', mySecret);

    final engine = OrderEngine();
    await engine.init();
    final partners = PartnerService();
    await partners.init();
    final sync = SyncService(engine, partnerService: partners);
    await sync.init(deferNetwork: true);
    return (sync, engine);
  }

  String encryptedDirective(String activeOrderId, String title,
      {int version = EncryptionHelper.writeVersion}) {
    final msg = SyncMessage(
      id: 'msg_$activeOrderId',
      type: SyncMessageType.dispatchOrder,
      senderId: 'director_device',
      targetCode: myCode,
      payload: {
        'activeOrderId': activeOrderId,
        'order': OrderItem(
          id: 'ord_tpl',
          title: title,
          description: 'Delivered by push',
          tier: 1,
          rewardTokens: 10,
        ).toJson(),
        'senderCode': 'DIR001',
        'senderName': 'Director',
        'assignedByDirector': true,
      },
    );
    return EncryptionHelper.encryptString(msg.encode(), mySecret,
        version: version);
  }

  group('Pushed directives', () {
    test('a payload queued by the push handler mounts on drain', () async {
      final (sync, engine) = await player();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('pending_background_push_v1',
          [encryptedDirective('active_push_1', 'Pushed Directive')]);

      await sync.processPendingBackgroundMessages();

      expect(engine.activeOrders.length, 1);
      expect(engine.activeOrders.first.id, 'active_push_1');
      expect(engine.activeOrders.first.order.title, 'Pushed Directive');
      expect(prefs.getStringList('pending_background_push_v1'), isNull,
          reason: 'the queue should be drained once applied');
    });

    test('several pushed directives all mount', () async {
      final (sync, engine) = await player();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('pending_background_push_v1', [
        encryptedDirective('active_a', 'First'),
        encryptedDirective('active_b', 'Second'),
      ]);

      await sync.processPendingBackgroundMessages();

      expect(engine.activeOrders.map((o) => o.id).toSet(),
          {'active_a', 'active_b'});
    });

    test('a pushed directive addressed elsewhere is ignored', () async {
      // Push must not become a way around addressing.
      final (sync, engine) = await player();

      final msg = SyncMessage(
        id: 'msg_not_mine',
        type: SyncMessageType.dispatchOrder,
        senderId: 'director_device',
        targetCode: 'SOMEONEELSE',
        payload: {
          'activeOrderId': 'active_not_mine',
          'order': OrderItem(id: 'o', title: 'Not Mine', description: 'x', tier: 1)
              .toJson(),
          'senderCode': 'DIR001',
        },
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('pending_background_push_v1',
          [EncryptionHelper.encryptString(msg.encode(), mySecret)]);

      await sync.processPendingBackgroundMessages();

      expect(engine.activeOrders, isEmpty);
    });

    test('both envelope versions mount during a mixed-build rollout', () async {
      final (sync, engine) = await player();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('pending_background_push_v1', [
        encryptedDirective('active_v1', 'From an older build', version: 1),
        encryptedDirective('active_v2', 'From a newer build', version: 2),
      ]);

      await sync.processPendingBackgroundMessages();

      expect(engine.activeOrders.map((o) => o.id).toSet(),
          {'active_v1', 'active_v2'});
    });

    test('a v2 payload altered in transit is dropped, not applied', () async {
      final (sync, engine) = await player();

      final genuine =
          encryptedDirective('active_tampered', 'Tampered', version: 2);
      final env = jsonDecode(utf8.decode(base64Decode(genuine)))
          as Map<String, dynamic>;
      final ct = base64Decode(env['ct'] as String);
      ct[0] ^= 0x01;
      final tampered = base64Encode(
          utf8.encode(jsonEncode({...env, 'ct': base64Encode(ct)})));

      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('pending_background_push_v1', [tampered]);

      await sync.processPendingBackgroundMessages();

      expect(engine.activeOrders, isEmpty);
    });

    test('an undecryptable payload does not abort the drain', () async {
      final (sync, engine) = await player();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('pending_background_push_v1', [
        'not decryptable with any known secret',
        encryptedDirective('active_survivor', 'Survivor'),
      ]);

      await sync.processPendingBackgroundMessages();

      expect(engine.activeOrders.length, 1);
      expect(engine.activeOrders.first.id, 'active_survivor');
    });
  });

  group('Background announcement dedup', () {
    test('a message the background isolate announced is not announced again',
        () async {
      // With the app swiped away nothing drains the queue, so the background
      // isolate has to raise the notification itself. When the app is merely
      // backgrounded the drain is alive and would announce it too.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          PushService.announcedByPushKey, ['msg_already_announced']);

      expect(await PushService.wasAnnouncedByPush('msg_already_announced'),
          isTrue);
      expect(await PushService.wasAnnouncedByPush('msg_other'), isFalse);
    });

    test('an unknown message is announced, failing open', () async {
      expect(await PushService.wasAnnouncedByPush('never_seen'), isFalse,
          reason: 'a silent directive is worse than a duplicate notification');
      expect(await PushService.wasAnnouncedByPush(''), isFalse);
    });

    test('a pushed directive still mounts even when already announced',
        () async {
      // Suppressing the notification must never suppress the directive.
      final (sync, engine) = await player();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          PushService.announcedByPushKey, ['msg_active_announced']);
      await prefs.setStringList('pending_background_push_v1',
          [encryptedDirective('active_announced', 'Quietly Mounted')]);

      await sync.processPendingBackgroundMessages();

      expect(engine.activeOrders.length, 1);
      expect(engine.activeOrders.first.id, 'active_announced');
    });
  });

  group('Platform capability', () {
    test('sending is allowed off Android, receiving is not', () {
      // The director runs on Windows. Gating sends on the Firebase SDK's
      // platform support would have made the whole migration useless there.
      expect(PushService.canSend, isTrue);
      expect(PushService.isSupported, isFalse,
          reason: 'these tests run on desktop, which cannot receive pushes');
    });
  });
}
