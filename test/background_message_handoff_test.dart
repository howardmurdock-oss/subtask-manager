import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/sync_service.dart';

/// The background isolate marks every message it receives as processed *before*
/// dispatching it, and the UI isolate skips anything already in that ledger.
///
/// So any message the background isolate could notify about but not act on was
/// consumed and lost: the notification appeared, the state change never
/// happened. A recall sent while the player's app was closed removed the
/// directive on the director's device and left it sitting on the player's.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const myCode = 'PLAYER1';

  Future<(SyncService, OrderEngine)> player() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pairing_code', myCode);
    await prefs.setString('pairing_secret', 'SECRET');

    final engine = OrderEngine();
    await engine.init();
    final partners = PartnerService();
    await partners.init();
    final sync = SyncService(engine, partnerService: partners);
    await sync.init(deferNetwork: true);
    return (sync, engine);
  }

  SyncMessage recallOf(String activeOrderId, String title, {String id = 'msg_recall_1'}) =>
      SyncMessage(
        id: id,
        type: SyncMessageType.orderStatusUpdate,
        senderId: 'director_device',
        targetCode: myCode,
        payload: {
          'activeOrderId': activeOrderId,
          'orderId': 'ord_tpl',
          'orderTitle': title,
          'status': 'recalled',
          'senderCode': 'DIR001',
          'senderId': 'director_device',
          'senderName': 'Director',
        },
      );

  group('Messages the background isolate cannot apply are handed over', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('a recall queued while the app was closed removes the directive',
        () async {
      final (sync, engine) = await player();

      engine.assignOrder(
        OrderItem(
          id: 'ord_tpl',
          title: 'Recalled Directive',
          description: 'Should not survive the recall',
          tier: 1,
          rewardTokens: 10,
        ),
        id: 'active_recall_1',
        assignedByDirector: true,
        assignedByPartnerCode: 'DIR001',
      );
      expect(engine.activeOrders.length, 1);

      final msg = recallOf('active_recall_1', 'Recalled Directive');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          'pending_background_messages_v1', [jsonEncode(msg.toJson())]);
      // The background isolate already banked this id when it arrived. Leaving
      // it in place is precisely what made the real handler skip the recall.
      await prefs.setStringList('bg_processed_message_ids', [msg.id]);

      await sync.processPendingBackgroundMessages();

      expect(engine.activeOrders, isEmpty,
          reason: 'the recall must remove the directive on the player device');
      expect(prefs.getStringList('pending_background_messages_v1'), isNull,
          reason: 'the queue should be drained once applied');
    });

    test('a poisoned processed-id ledger does not block the handed-over message',
        () async {
      // Reproduces the original failure directly: the id is in the ledger the
      // UI isolate loads at startup, so without clearing it the handler returns
      // early and the directive stays put.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pairing_code', myCode);
      await prefs.setString('pairing_secret', 'SECRET');

      // The directive must already be mounted before SyncService starts, since
      // init() drains the hand-off queue itself — which is exactly how this
      // arrives in the field: the app launches with the recall already waiting.
      final engine = OrderEngine();
      await engine.init();
      engine.assignOrder(
        OrderItem(
          id: 'ord_tpl',
          title: 'Sticky Directive',
          description: 'Recalled while the app was shut',
          tier: 1,
        ),
        id: 'active_recall_2',
        assignedByDirector: true,
        assignedByPartnerCode: 'DIR001',
      );
      expect(engine.activeOrders.length, 1);

      final msg = recallOf('active_recall_2', 'Sticky Directive',
          id: 'msg_already_seen');
      await prefs.setStringList('bg_processed_message_ids', [msg.id]);
      await prefs.setStringList(
          'pending_background_messages_v1', [jsonEncode(msg.toJson())]);

      final partners = PartnerService();
      await partners.init();
      final sync = SyncService(engine, partnerService: partners);
      // init() loads the poisoned ledger and then drains the queue.
      await sync.init(deferNetwork: true);

      expect(engine.activeOrders, isEmpty);
      expect(sync.remoteActiveOrders, isEmpty);
    });

    test('a handed-over message addressed to someone else is still ignored',
        () async {
      // The hand-off must not become a way around recipient checks.
      final (sync, engine) = await player();

      engine.assignOrder(
        OrderItem(id: 'ord_tpl', title: 'Not Yours', description: 'x', tier: 1),
        id: 'active_other',
        assignedByDirector: true,
      );

      final msg = SyncMessage(
        id: 'msg_for_someone_else',
        type: SyncMessageType.orderStatusUpdate,
        senderId: 'director_device',
        targetCode: 'SOMEONEELSE',
        payload: {
          'activeOrderId': 'active_other',
          'orderTitle': 'Not Yours',
          'status': 'recalled',
          'senderCode': 'DIR001',
        },
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          'pending_background_messages_v1', [jsonEncode(msg.toJson())]);

      await sync.processPendingBackgroundMessages();

      expect(engine.activeOrders.length, 1,
          reason: 'a recall aimed at another device must not apply here');
    });

    test('a malformed queued message does not abort the rest of the drain',
        () async {
      final (sync, engine) = await player();

      engine.assignOrder(
        OrderItem(id: 'ord_tpl', title: 'Survivor', description: 'x', tier: 1),
        id: 'active_survivor',
        assignedByDirector: true,
        assignedByPartnerCode: 'DIR001',
      );

      final good = recallOf('active_survivor', 'Survivor', id: 'msg_good');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('pending_background_messages_v1', [
        'not json at all',
        jsonEncode(good.toJson()),
      ]);

      await sync.processPendingBackgroundMessages();

      expect(engine.activeOrders, isEmpty,
          reason: 'the valid recall must still be applied');
    });
  });
}
