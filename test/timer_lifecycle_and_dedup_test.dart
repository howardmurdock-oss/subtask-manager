import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/active_order.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Action Timer Resilience & Sync Deduplication Tests', () {
    test('startActionTimer sets actionTimerEndsAt and currentActionSecondsRemaining updates dynamically', () {
      final engine = OrderEngine();
      final order = OrderItem(
        id: 'ord_plank',
        title: '60-Second Plank',
        description: 'Hold a straight arm plank',
        durationType: DurationType.actionTimer,
        actionDurationSeconds: 60,
      );

      final active = engine.assignOrder(order);
      expect(active.isActionTimerRunning, isFalse);
      expect(active.actionSecondsRemaining, equals(60));

      engine.startActionTimer(active.id);
      final running = engine.activeOrders.firstWhere((o) => o.id == active.id);
      expect(running.isActionTimerRunning, isTrue);
      expect(running.actionTimerEndsAt, isNotNull);
      expect(running.currentActionSecondsRemaining, inInclusiveRange(58, 60));
    });

    test('onAppResumed updates running timer accurately without resetting to start', () {
      final engine = OrderEngine();
      final order = OrderItem(
        id: 'ord_kneel',
        title: 'Wall Sit Routine',
        description: 'Maintain 90-degree wall sit',
        durationType: DurationType.actionTimer,
        actionDurationSeconds: 120,
      );

      final active = engine.assignOrder(order);
      engine.startActionTimer(active.id);

      // Simulate 30 seconds passing while in background / camera
      final index = engine.activeOrders.indexWhere((o) => o.id == active.id);
      final current = engine.activeOrders[index];
      engine.activeOrders[index] = current.copyWith(
        actionTimerEndsAt: DateTime.now().add(const Duration(seconds: 90)),
        actionSecondsRemaining: 120,
      );

      // Trigger app resume
      engine.onAppResumed();

      final resumed = engine.activeOrders.firstWhere((o) => o.id == active.id);
      expect(resumed.isActionTimerRunning, isTrue);
      expect(resumed.isActionTimerFinished, isFalse);
      expect(resumed.actionSecondsRemaining, inInclusiveRange(88, 91));
      expect(resumed.currentActionSecondsRemaining, inInclusiveRange(88, 91));
    });

    test('SyncService dispatchOrder does not reset running order when re-sent by network / relay', () async {
      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();
      final sync = SyncService(engine, partnerService: partnerService);

      final order = OrderItem(
        id: 'ord_chores',
        title: 'Dishes Cleanup',
        description: 'Clean the kitchen dishes',
        durationType: DurationType.actionTimer,
        actionDurationSeconds: 300,
      );

      // Initial assignment
      final initialActive = engine.assignOrder(
        order,
        id: 'active_123',
        assignedByDirector: true,
        assignedByPartnerCode: 'DIR999',
        assignedByPartnerName: 'My Director',
      );

      // Submissive starts action timer and 45 seconds elapse
      engine.startActionTimer(initialActive.id);
      final index = engine.activeOrders.indexWhere((o) => o.id == initialActive.id);
      engine.activeOrders[index] = engine.activeOrders[index].copyWith(
        actionSecondsRemaining: 255,
        actionTimerEndsAt: DateTime.now().add(const Duration(seconds: 255)),
      );

      // Submissive leaves app to take picture, returns after 15s.
      // Replay of dispatchOrder packet arrives:
      final replayedOrder = engine.assignOrder(
        order,
        id: 'active_123',
        assignedByDirector: true,
        assignedByPartnerCode: 'DIR999',
        assignedByPartnerName: 'My Director',
      );

      // Verify that assignOrder preserved the running order and did NOT reset timer
      expect(replayedOrder.id, equals('active_123'));
      expect(replayedOrder.isActionTimerRunning, isTrue);
      expect(replayedOrder.currentActionSecondsRemaining, inInclusiveRange(250, 256));

      sync.dispose();
      partnerService.dispose();
      engine.dispose();
    });
  });
}
