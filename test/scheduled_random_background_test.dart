import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/active_order.dart';
import 'package:orders_app/models/user_stats.dart';
import 'package:orders_app/models/scheduled_order_rule.dart';
import 'package:orders_app/services/schedule_service.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/services/partner_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Scheduled Random Task & Background Execution Tests', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
    });

    test('ScheduledOrderRule serializes and deserializes stagedOrder accurately', () {
      final staged = OrderItem(
        id: 'ord_staged_99',
        title: 'Hydrate 500ml',
        description: 'Drink a full glass of water immediately',
        rewardTokens: 10,
        tier: 1,
      );

      final rule = ScheduledOrderRule(
        title: 'Afternoon Hydration',
        targetType: ScheduleTargetType.playerSelfDraw,
        timingMode: ScheduleTimingMode.randomWindow,
        frequency: RepeatFrequency.daily,
        windowStartHour: 13,
        windowStartMinute: 0,
        windowEndHour: 15,
        windowEndMinute: 0,
        stagedOrder: staged,
      );

      final json = rule.toJson();
      final decoded = ScheduledOrderRule.fromJson(json);

      expect(decoded.stagedOrder, isNotNull);
      expect(decoded.stagedOrder!.id, equals('ord_staged_99'));
      expect(decoded.stagedOrder!.title, equals('Hydrate 500ml'));
      expect(decoded.stagedOrder!.rewardTokens, equals(10));
    });

    test('addRule automatically stages a random order when rule is created', () async {
      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();
      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();

      final schedule = ScheduleService();
      schedule.attachDependencies(
        orderEngine: engine,
        syncService: sync,
        partnerService: partnerService,
      );

      final rule = ScheduledOrderRule(
        title: 'Surprise Chores',
        targetType: ScheduleTargetType.playerSelfDraw,
        timingMode: ScheduleTimingMode.randomWindow,
        frequency: RepeatFrequency.daily,
        windowStartHour: 10,
        windowStartMinute: 0,
        windowEndHour: 12,
        windowEndMinute: 0,
      );

      await schedule.addRule(rule);

      expect(schedule.rules.length, equals(1));
      final savedRule = schedule.rules.first;
      expect(savedRule.stagedOrder, isNotNull);
      expect(savedRule.stagedOrder!.title.isNotEmpty, isTrue);
    });

    test('Opening app hours after scheduled window assigns task with true window timestamp (not app launch time)', () async {
      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();
      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();

      final schedule = ScheduleService();
      schedule.attachDependencies(
        orderEngine: engine,
        syncService: sync,
        partnerService: partnerService,
      );

      final staged = OrderItem(
        id: 'ord_window_drill',
        title: 'Core Workout',
        description: 'Do 3 planks for 1 minute each',
        rewardTokens: 25,
        tier: 2,
        durationMinutes: 45,
        durationType: DurationType.deadlineCountdown,
      );

      // Scheduled window was 10:45 AM - 12:00 PM today.
      // Scheduled trigger was 2 hours ago (guaranteed past trigger regardless of test execution time)
      final now = DateTime.now();
      final scheduledTrigger = now.subtract(const Duration(hours: 2));

      final rule = ScheduledOrderRule(
        id: 'rule_core_drill',
        title: 'Midday Surprise Drill',
        targetType: ScheduleTargetType.playerSelfDraw,
        timingMode: ScheduleTimingMode.randomWindow,
        frequency: RepeatFrequency.daily,
        nextTriggerTime: scheduledTrigger,
        windowStartHour: scheduledTrigger.hour,
        windowStartMinute: scheduledTrigger.minute > 5 ? scheduledTrigger.minute - 5 : 0,
        windowEndHour: (scheduledTrigger.hour + 1) % 24,
        windowEndMinute: 0,
        stagedOrder: staged,
      );

      await schedule.addRule(rule);

      // Simulate opening the app at 1:10 PM (nearly 2 hours after scheduledTrigger)
      await schedule.checkDueRules();

      // Verify task is active on engine
      expect(engine.activeOrders.length, equals(1));
      final active = engine.activeOrders.first;
      expect(active.order.title, equals('Core Workout'));

      // Assigned timestamp MUST match scheduledTrigger (11:15 AM), NOT the launch time!
      expect(active.assignedAt, equals(scheduledTrigger));

      // Fair deadline calculation: because the deadline passed while asleep, expiresAt must be extended fairly from now
      expect(active.expiresAt!.isAfter(DateTime.now()), isTrue);

      // Next recurrence should have been re-armed with a fresh staged order for tomorrow
      final updatedRule = schedule.rules.firstWhere((r) => r.id == 'rule_core_drill');
      expect(updatedRule.nextTriggerTime.isAfter(DateTime.now()), isTrue);
      expect(updatedRule.stagedOrder, isNotNull);
    });

    test('SyncService processPendingBackgroundMessages preserves background assignedAt timestamp', () async {
      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();
      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();

      final prefs = await SharedPreferences.getInstance();
      final triggerTime = DateTime.now().subtract(const Duration(hours: 1));

      final queuedOrder = {
        'type': 'dispatchOrder',
        'activeOrderId': 'bg_queued_101',
        'order': {
          'id': 'ord_desk_clean',
          'title': 'Clean Desk',
          'description': 'Tidy work space',
          'tier': 1,
          'rewardTokens': 15,
        },
        'senderName': 'Scheduled Task',
        'senderId': '__self__',
        'senderCode': '',
        'assignedByDirector': false,
        'assignedAt': triggerTime.toIso8601String(),
      };

      await prefs.setStringList('pending_background_orders_v1', [jsonEncode(queuedOrder)]);

      await sync.processPendingBackgroundMessages();

      expect(engine.activeOrders.length, equals(1));
      final assigned = engine.activeOrders.first;
      expect(assigned.id, equals('bg_queued_101'));
      expect(assigned.order.title, equals('Clean Desk'));
      expect(assigned.assignedAt.toIso8601String(), equals(triggerTime.toIso8601String()));
    });

    test('attachDependencies immediately executes overdue rules on app launch', () async {
      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();
      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();

      final prefs = await SharedPreferences.getInstance();
      final triggerTime = DateTime.now().subtract(const Duration(hours: 3));

      final overdueRule = ScheduledOrderRule(
        id: 'rule_overdue_launch',
        title: 'Morning Task',
        targetType: ScheduleTargetType.playerSelfDraw,
        timingMode: ScheduleTimingMode.randomWindow,
        frequency: RepeatFrequency.daily,
        nextTriggerTime: triggerTime,
        windowStartHour: triggerTime.hour,
        windowStartMinute: 0,
        windowEndHour: (triggerTime.hour + 1) % 24,
        windowEndMinute: 0,
        stagedOrder: OrderItem(
          id: 'ord_morning_task',
          title: 'Morning Pushups',
          description: 'Do 20 pushups',
          rewardTokens: 10,
          tier: 1,
        ),
      );

      // Save rule into storage as if it was created in a previous session
      await prefs.setString('saved_scheduled_rules_v1', jsonEncode([overdueRule.toJson()]));

      final schedule = ScheduleService();
      // Wait for async storage load in constructor
      await Future.delayed(const Duration(milliseconds: 50));

      // Attaching dependencies should trigger checkDueRules() immediately
      schedule.attachDependencies(
        orderEngine: engine,
        syncService: sync,
        partnerService: partnerService,
      );

      // Engine should immediately have the active order assigned without waiting for ticker
      expect(engine.activeOrders.length, equals(1));
      expect(engine.activeOrders.first.order.title, equals('Morning Pushups'));
      expect(engine.activeOrders.first.assignedAt, equals(triggerTime));
    });

    test('Scheduled task is successfully assigned even if the order was previously completed in history', () async {
      final engine = OrderEngine();
      await engine.init();

      // Pre-populate completed directive in history
      engine.stats.history.add(DisciplineLogEntry(
        id: 'rec_completed_past',
        orderTitle: 'Daily Pushups',
        category: 'Fitness',
        tier: 1,
        tokenDelta: 10,
        isSuccess: true,
        reason: 'Completed yesterday',
        timestamp: DateTime.now().subtract(const Duration(days: 1)),
      ));

      final partnerService = PartnerService();
      await partnerService.init();
      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();

      final prefs = await SharedPreferences.getInstance();
      final triggerTime = DateTime.now().subtract(const Duration(minutes: 10));

      final queuedOrder = {
        'type': 'dispatchOrder',
        'isScheduled': true,
        'activeOrderId': 'sched_bg_pushups_today',
        'order': {
          'id': 'ord_pushups_template',
          'title': 'Daily Pushups',
          'description': 'Do 25 pushups',
          'tier': 1,
          'rewardTokens': 15,
        },
        'senderName': 'Scheduled Task',
        'senderId': '__self__',
        'senderCode': '',
        'assignedByDirector': false,
        'assignedAt': triggerTime.toIso8601String(),
      };

      await prefs.setStringList('pending_background_orders_v1', [jsonEncode(queuedOrder)]);

      // Draining pending background orders must mount the new active order and NOT drop it
      await sync.processPendingBackgroundMessages();

      expect(engine.activeOrders.length, equals(1));
      expect(engine.activeOrders.first.order.title, equals('Daily Pushups'));
      expect(engine.activeOrders.first.id, equals('sched_bg_pushups_today'));
      expect(engine.activeOrders.first.status, equals(OrderStatus.active));
    });

    test('OrderEngine assignOrder assigns fresh active order when previous instance was completed', () async {
      final engine = OrderEngine();
      await engine.init();

      final orderItem = OrderItem(
        id: 'ord_water_500ml',
        title: 'Drink Water',
        description: 'Drink 500ml of water',
        rewardTokens: 5,
        tier: 1,
      );

      // 1. Assign and complete morning instance
      final firstActive = engine.assignOrder(orderItem);
      expect(engine.activeOrders.length, equals(1));
      engine.completeOrder(firstActive.id);
      expect(engine.activeOrders.first.status, equals(OrderStatus.completed));

      // 2. Afternoon scheduled trigger assigns same task
      final secondActive = engine.assignOrder(orderItem);
      expect(secondActive.status, equals(OrderStatus.active));
      expect(engine.activeOrders.length, equals(1));
      expect(engine.activeOrders.first.status, equals(OrderStatus.active));
    });
  });
}
