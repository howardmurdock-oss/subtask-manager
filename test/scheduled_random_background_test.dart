import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/active_order.dart';
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
      // Trigger was at 11:15 AM today.
      final today = DateTime.now();
      final scheduledTrigger = DateTime(today.year, today.month, today.day, 11, 15);

      final rule = ScheduledOrderRule(
        id: 'rule_core_drill',
        title: 'Midday Surprise Drill',
        targetType: ScheduleTargetType.playerSelfDraw,
        timingMode: ScheduleTimingMode.randomWindow,
        frequency: RepeatFrequency.daily,
        nextTriggerTime: scheduledTrigger,
        windowStartHour: 10,
        windowStartMinute: 45,
        windowEndHour: 12,
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
  });
}
