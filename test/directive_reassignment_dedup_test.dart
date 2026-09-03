import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/active_order.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/models/user_stats.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Directive Reassignment Deduplication & Startup Ingestion Tests', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
    });

    test('Replayed dispatchOrder for an active directive does not reassign or duplicate', () async {
      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();

      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();

      final orderItem = OrderItem(
        id: 'pushups_daily_101',
        title: 'Daily Pushup Challenge',
        description: 'Complete 30 pushups',
        rewardTokens: 15,
      );

      // Director dispatches directive
      final dispatchMsg = SyncMessage(
        id: 'msg_dispatch_001',
        type: SyncMessageType.dispatchOrder,
        senderId: 'remote_director_device',
        payload: {
          'activeOrderId': 'active_uuid_999',
          'order': orderItem.toJson(),
          'senderCode': 'DIR888',
          'senderName': 'Director Sovereign',
          'senderId': 'remote_director_device',
          'assignedByDirector': true,
        },
      );

      // 1. First arrival: directive is assigned
      await sync.handleIncomingSyncMessage(dispatchMsg);

      expect(engine.activeOrders.length, equals(1));
      expect(engine.activeOrders.first.id, equals('active_uuid_999'));
      expect(engine.activeOrders.first.order.title, equals('Daily Pushup Challenge'));
      expect(sync.isDirectiveHandled(activeOrderId: 'active_uuid_999'), isTrue);
      expect(sync.isDirectiveHandled(title: 'Daily Pushup Challenge'), isTrue);

      // 2. Replay arrival (e.g. ntfy 24h replay or app relaunch): must be silently ignored
      final replayMsg = SyncMessage(
        id: 'msg_dispatch_001_replay',
        type: SyncMessageType.dispatchOrder,
        senderId: 'remote_director_device',
        payload: {
          'activeOrderId': 'active_uuid_999',
          'order': orderItem.toJson(),
          'senderCode': 'DIR888',
          'senderName': 'Director Sovereign',
          'senderId': 'remote_director_device',
          'assignedByDirector': true,
        },
      );

      await sync.handleIncomingSyncMessage(replayMsg);

      // Still exactly 1 directive in engine - no duplicate assignment!
      expect(engine.activeOrders.length, equals(1));
      expect(engine.activeOrders.first.id, equals('active_uuid_999'));

      sync.dispose();
      partnerService.dispose();
      engine.dispose();
    });

    test('Completed directive in history is not resurrected by replayed dispatchOrder', () async {
      final engine = OrderEngine();
      await engine.init();

      // Pre-populate completed directive in history
      engine.stats.history.add(DisciplineLogEntry(
        id: 'rec_completed_777',
        orderTitle: 'Morning Stretch',
        category: 'Fitness',
        tier: 1,
        tokenDelta: 10,
        isSuccess: true,
        reason: 'Completed on time',
        timestamp: DateTime.now().subtract(const Duration(hours: 2)),
      ));

      final partnerService = PartnerService();
      await partnerService.init();

      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();

      // Handled ledger should recognize history
      expect(sync.isDirectiveHandled(title: 'Morning Stretch'), isTrue);

      final orderItem = OrderItem(
        id: 'pushups_catalog_id',
        title: 'Morning Stretch',
        description: 'Do morning stretch',
        rewardTokens: 10,
      );

      final replayedDispatch = SyncMessage(
        id: 'msg_replay_completed',
        type: SyncMessageType.dispatchOrder,
        senderId: 'director_xyz',
        payload: {
          'activeOrderId': 'old_active_id',
          'order': orderItem.toJson(),
          'senderCode': 'DIR999',
          'senderName': 'Director',
          'assignedByDirector': true,
        },
      );

      await sync.handleIncomingSyncMessage(replayedDispatch);

      // Must NOT be resurrected into active orders
      expect(engine.activeOrders.where((o) => o.order.title == 'Morning Stretch'), isEmpty);

      sync.dispose();
      partnerService.dispose();
      engine.dispose();
    });

    test('Pending background orders ingest instantaneously on init and preserve activeOrderId', () async {
      final prefs = await SharedPreferences.getInstance();

      final bgOrderPayload = {
        'activeOrderId': 'bg_assigned_uuid_456',
        'order': OrderItem(
          id: 'bg_item_1',
          title: 'Hydration Check',
          description: 'Drink 500ml water',
          rewardTokens: 5,
        ).toJson(),
        'senderCode': 'DIR777',
        'senderName': 'Director Elena',
        'senderId': 'director_elena_device',
        'assignedByDirector': true,
        'messageId': 'bg_msg_001',
      };

      // Background isolate saved order while app was terminated
      await prefs.setStringList('pending_background_orders_v1', [jsonEncode(bgOrderPayload)]);

      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();

      final sync = SyncService(engine, partnerService: partnerService);
      // init() immediately drains pending background orders without waiting for network
      await sync.init();

      // Verify order is available right away
      expect(engine.activeOrders.length, equals(1));
      expect(engine.activeOrders.first.id, equals('bg_assigned_uuid_456'));
      expect(engine.activeOrders.first.order.title, equals('Hydration Check'));
      expect(sync.isDirectiveHandled(activeOrderId: 'bg_assigned_uuid_456'), isTrue);

      // Verify pending queue in prefs was cleared
      final remainingPending = prefs.getStringList('pending_background_orders_v1') ?? [];
      expect(remainingPending, isEmpty);

      sync.dispose();
      partnerService.dispose();
      engine.dispose();
    });

    test('Handled directive ledger persists across service restarts in SharedPreferences', () async {
      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();

      final sync1 = SyncService(engine, partnerService: partnerService);
      await sync1.init();

      sync1.markDirectiveHandled(
        activeOrderId: 'saved_uuid_101',
        title: 'Bed Making Routine',
      );

      sync1.dispose();

      // Launch fresh SyncService instance to simulate app restart
      final sync2 = SyncService(engine, partnerService: partnerService);
      await sync2.init();

      expect(sync2.isDirectiveHandled(activeOrderId: 'saved_uuid_101'), isTrue);
      expect(sync2.isDirectiveHandled(title: 'Bed Making Routine'), isTrue);

      sync2.dispose();
      partnerService.dispose();
      engine.dispose();
    });
  });
}
