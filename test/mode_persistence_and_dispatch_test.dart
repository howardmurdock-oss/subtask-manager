import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/order_pack.dart';
import 'package:orders_app/models/active_order.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/views/home_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Mode Persistence & Library Dispatch Tests', () {
    test('SharedPreferences correctly stores and retrieves AppRole', () async {
      SharedPreferences.setMockInitialValues({'app_active_role': 'director'});
      final prefs = await SharedPreferences.getInstance();

      final saved = prefs.getString('app_active_role');
      expect(saved, 'director');

      final role = AppRole.values.firstWhere((e) => e.name == saved);
      expect(role, AppRole.director);

      await prefs.setString('app_active_role', 'player');
      expect(prefs.getString('app_active_role'), 'player');
    });

    test('OrderItem formattedTiming produces clean readable strings for all timing models', () {
      final instantOrder = OrderItem(
        title: 'Instant Task',
        description: 'Test',
        durationType: DurationType.instant,
      );
      expect(instantOrder.formattedTiming, 'Instant');

      final actionSecOrder = OrderItem(
        title: '30s Drill',
        description: 'Test',
        durationType: DurationType.actionTimer,
        actionDurationSeconds: 45,
      );
      expect(actionSecOrder.formattedTiming, '45s Action');

      final actionMinOrder = OrderItem(
        title: '2m Drill',
        description: 'Test',
        durationType: DurationType.actionTimer,
        actionDurationSeconds: 120,
      );
      expect(actionMinOrder.formattedTiming, '2m Action');

      final deadlineOrder = OrderItem(
        title: 'Deadline Task',
        description: 'Test',
        durationType: DurationType.deadlineCountdown,
        durationMinutes: 45,
      );
      expect(deadlineOrder.formattedTiming, '45m Deadline');

      final deadlineHoursOrder = OrderItem(
        title: 'Long Deadline Task',
        description: 'Test',
        durationType: DurationType.deadlineCountdown,
        durationMinutes: 120,
      );
      expect(deadlineHoursOrder.formattedTiming, '2h Deadline');

      final actionHoursOrder = OrderItem(
        title: 'Long Action Task',
        description: 'Test',
        durationType: DurationType.actionTimer,
        actionDurationSeconds: 7200,
      );
      expect(actionHoursOrder.formattedTiming, '2h Action');

      final dualOrder = OrderItem(
        title: 'Action with Deadline Task',
        description: 'Test',
        durationType: DurationType.actionWithDeadline,
        actionDurationSeconds: 300,
        durationMinutes: 60,
      );
      expect(dualOrder.formattedTiming, '5m Action (1h Window)');

      final dailyOrder = OrderItem(
        title: 'Daily Task',
        description: 'Test',
        durationType: DurationType.dailyWindow,
      );
      expect(dailyOrder.formattedTiming, 'Daily Window');
    });

    test('Customizing existing pack order preserves or overrides desired fields', () {
      final pack = OrderPack(
        id: 'pack_1',
        title: 'Core Pack',
        description: 'Standard library pack',
        author: 'System',
        orders: [
          OrderItem(
            title: 'Standard Drill',
            description: 'Original description',
            tier: 2,
            durationType: DurationType.actionTimer,
            actionDurationSeconds: 120,
            rewardTokens: 20,
            penaltyTokens: 30,
          ),
        ],
      );

      final original = pack.orders.first;
      expect(original.title, 'Standard Drill');

      // Director customizes duration and reward
      final customized = original.copyWith(
        actionDurationSeconds: 240,
        rewardTokens: 40,
        description: 'Overridden custom instruction for this session',
      );

      expect(customized.title, 'Standard Drill');
      expect(customized.actionDurationSeconds, 240);
      expect(customized.rewardTokens, 40);
      expect(customized.description, 'Overridden custom instruction for this session');
      expect(customized.penaltyTokens, 30); // Preserved
    });

    test('SyncService retains copy of dispatched order on Director side and supports clear & recall', () {
      final engine = OrderEngine();
      final sync = SyncService(engine);

      final order = OrderItem(
        id: 'ord_123',
        title: 'Discipline Routine',
        description: 'Stand at attention for 5 minutes',
        durationType: DurationType.actionTimer,
        actionDurationSeconds: 300,
        rewardTokens: 15,
        penaltyTokens: 25,
      );

      final partner = PartnerContact(
        id: 'partner_1',
        displayName: 'Submissive One',
        pairingCode: 'SUB-1234',
        pairingSecret: 'sec_1234',
        role: PartnerRole.submissive,
      );

      sync.dispatchOrderToPlayer(order, targetPartner: partner);

      expect(sync.remoteActiveOrders.isNotEmpty, isTrue);
      expect(sync.remoteActiveOrders.first.order.title, 'Discipline Routine');
      expect(sync.remoteActiveOrders.first.assignedByPartnerName, 'Submissive One');
      expect(sync.remoteActiveOrders.first.assignedByPartnerCode, 'SUB-1234');
      expect(sync.remoteActiveOrders.first.status, OrderStatus.active);

      // Test clearing active order
      final activeId = sync.remoteActiveOrders.first.id;
      sync.clearRemoteActiveOrder(activeId);
      expect(sync.remoteActiveOrders.isEmpty, isTrue);
    });

    test('Recalling dispatched order removes active order from player engine', () async {
      final playerEngine = OrderEngine();
      final playerSync = SyncService(playerEngine);

      final order = OrderItem(
        id: 'ord_456',
        title: 'Posture Check',
        description: 'Sit straight for 10 minutes',
        durationType: DurationType.actionTimer,
        actionDurationSeconds: 600,
      );

      final active = playerEngine.assignOrder(
        order,
        id: 'active_456',
        assignedByDirector: true,
        assignedByPartnerCode: 'DIR-9999',
        assignedByPartnerName: 'Master Director',
      );

      expect(playerEngine.activeOrders.length, 1);
      expect(playerEngine.activeOrders.first.id, 'active_456');

      // Process incoming recall message
      final recallMsg = SyncMessage(
        type: SyncMessageType.orderStatusUpdate,
        senderId: 'dir_device_1',
        payload: {
          'activeOrderId': 'active_456',
          'orderId': 'ord_456',
          'orderTitle': 'Posture Check',
          'status': 'recalled',
          'senderName': 'Master Director',
        },
      );

      await playerSync.handleIncomingSyncMessage(recallMsg);

      expect(playerEngine.activeOrders.isEmpty, isTrue);
    });

    test('Resilient queue clearance methods wipe orders across sync and engine', () {
      final engine = OrderEngine();
      final sync = SyncService(engine);

      final order1 = OrderItem(id: 'ord_1', title: 'Task 1', description: 'Desc');
      final order2 = OrderItem(id: 'ord_2', title: 'Task 2', description: 'Desc');

      engine.assignOrder(order1, id: 'act_1');
      engine.assignOrder(order2, id: 'act_2');

      sync.dispatchOrderToPlayer(order1);
      sync.dispatchOrderToPlayer(order2);

      expect(sync.remoteActiveOrders.length, 2);
      expect(engine.activeOrders.length, 2);

      // Deep clear single order by title
      sync.clearRemoteActiveOrder('act_1', orderTitle: 'Task 1');
      expect(sync.remoteActiveOrders.length, 1);
      expect(engine.activeOrders.length, 1);

      // Purge everything
      sync.purgeAllDirectivesAndReviews();
      expect(sync.remoteActiveOrders.isEmpty, isTrue);
      expect(sync.remoteReviewOrders.isEmpty, isTrue);
      expect(engine.activeOrders.isEmpty, isTrue);
    });
  });
}
