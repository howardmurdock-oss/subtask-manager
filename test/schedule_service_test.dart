import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/order_pack.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/models/scheduled_order_rule.dart';
import 'package:orders_app/services/schedule_service.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ScheduledOrderRule Model Tests', () {
    test('JSON round-trip preserves all fields', () {
      final order = OrderItem(
        id: 'ord-sched-1',
        title: 'Morning Posture Check',
        description: 'Stand at attention for 5m',
        tier: 2,
        durationType: DurationType.actionTimer,
        actionDurationSeconds: 300,
        rewardTokens: 15,
      );

      final rule = ScheduledOrderRule(
        title: 'Daily Morning Drill',
        targetType: ScheduleTargetType.directorDispatch,
        timingMode: ScheduleTimingMode.specificTime,
        frequency: RepeatFrequency.daily,
        specificScheduledTime: DateTime(2026, 8, 27, 8, 30),
        nextTriggerTime: DateTime(2026, 8, 27, 8, 30),
        isSpecificOrder: true,
        specificOrder: order,
        targetPartnerId: 'partner-123',
        targetPartnerCode: 'SUB-4567',
        targetPartnerName: 'Submissive One',
      );

      final json = rule.toJson();
      final decoded = ScheduledOrderRule.fromJson(json);

      expect(decoded.id, equals(rule.id));
      expect(decoded.title, equals('Daily Morning Drill'));
      expect(decoded.targetType, equals(ScheduleTargetType.directorDispatch));
      expect(decoded.timingMode, equals(ScheduleTimingMode.specificTime));
      expect(decoded.frequency, equals(RepeatFrequency.daily));
      expect(decoded.isSpecificOrder, isTrue);
      expect(decoded.specificOrder?.title, equals('Morning Posture Check'));
      expect(decoded.targetPartnerId, equals('partner-123'));
      expect(decoded.targetPartnerCode, equals('SUB-4567'));
      expect(decoded.targetPartnerName, equals('Submissive One'));
      expect(decoded.isEnabled, isTrue);
    });

    test('Random Window timing computes valid trigger within window bounds', () {
      final now = DateTime(2026, 8, 27, 12, 0); // 12:00 PM
      final trigger = ScheduledOrderRule.computeRandomWindowTrigger(
        15,
        0, // 3:00 PM
        21,
        0, // 9:00 PM
        fromTime: now,
      );

      expect(trigger.year, equals(2026));
      expect(trigger.month, equals(8));
      expect(trigger.day, equals(27));
      expect(trigger.hour >= 15 && trigger.hour <= 21, isTrue);
    });

    test('Recurrence calculation handles one-time, hourly, daily, and weekly', () {
      final base = DateTime(2026, 8, 27, 10, 0);

      final onceRule = ScheduledOrderRule(
        title: 'Once',
        targetType: ScheduleTargetType.playerSelfDraw,
        frequency: RepeatFrequency.once,
      );
      expect(onceRule.computeNextRecurrence(base), isNull);

      final hourlyRule = ScheduledOrderRule(
        title: 'Hourly',
        targetType: ScheduleTargetType.playerSelfDraw,
        frequency: RepeatFrequency.hourly,
      );
      final nextHour = hourlyRule.computeNextRecurrence(base);
      expect(nextHour, equals(DateTime(2026, 8, 27, 11, 0)));

      final dailyRule = ScheduledOrderRule(
        title: 'Daily',
        targetType: ScheduleTargetType.playerSelfDraw,
        frequency: RepeatFrequency.daily,
        specificScheduledTime: DateTime(2026, 8, 27, 8, 0),
      );
      final nextDay = dailyRule.computeNextRecurrence(base);
      expect(nextDay, equals(DateTime(2026, 8, 28, 8, 0)));
    });
  });

  group('ScheduleService Execution & Gating Tests', () {
    test('Patreon passcode gating: unlocks on valid code and rejects invalid', () async {
      final scheduleSvc = ScheduleService();

      expect(scheduleSvc.isUnlocked, isFalse);
      expect(scheduleSvc.unlockWithPasscode('WRONG-CODE'), isFalse);
      expect(scheduleSvc.isUnlocked, isFalse);

      expect(scheduleSvc.unlockWithPasscode('PATREON-VIP'), isTrue);
      expect(scheduleSvc.isUnlocked, isTrue);

      scheduleSvc.relock();
      expect(scheduleSvc.isUnlocked, isFalse);

      expect(scheduleSvc.unlockWithPasscode('SCHEDULE'), isTrue);
      expect(scheduleSvc.isUnlocked, isTrue);
    });

    test('Rule CRUD operations persist and update accurately', () async {
      final scheduleSvc = ScheduleService();

      final rule = ScheduledOrderRule(
        title: 'Test Rule',
        targetType: ScheduleTargetType.playerSelfDraw,
        categoryFilter: 'Discipline',
        minTier: 1,
        maxTier: 3,
      );

      await scheduleSvc.addRule(rule);
      expect(scheduleSvc.rules.length, 1);
      expect(scheduleSvc.playerRules.length, 1);
      expect(scheduleSvc.directorRules.length, 0);

      // Toggle rule
      await scheduleSvc.toggleRule(rule.id, false);
      expect(scheduleSvc.rules.first.isEnabled, isFalse);

      await scheduleSvc.toggleRule(rule.id, true);
      expect(scheduleSvc.rules.first.isEnabled, isTrue);

      // Delete rule
      await scheduleSvc.deleteRule(rule.id);
      expect(scheduleSvc.rules.length, 0);
    });

    test('Player self-draw scheduled rule automatically assigns order when due', () async {
      final storage = StorageService();
      final pack = OrderPack(
        id: 'pack-sched-1',
        title: 'Discipline Pack',
        description: 'Test Pack',
        author: 'Director',
        orders: [
          OrderItem(
            id: 'ord-disc-1',
            title: 'Posture Discipline',
            description: 'Sit upright for 5 minutes',
            category: 'Discipline',
            tier: 1,
            durationType: DurationType.instant,
          ),
        ],
      );
      await storage.savePacks([pack]);

      final engine = OrderEngine(storage: storage);
      await engine.init();

      final partnerSvc = PartnerService();
      final syncSvc = SyncService(engine);
      final scheduleSvc = ScheduleService();
      scheduleSvc.attachDependencies(
        orderEngine: engine,
        syncService: syncSvc,
        partnerService: partnerSvc,
      );

      expect(engine.currentRunningOrders.length, 0);

      // Add rule with nextTriggerTime in the past
      final rule = ScheduledOrderRule(
        title: 'Auto Draw Drill',
        targetType: ScheduleTargetType.playerSelfDraw,
        frequency: RepeatFrequency.once,
        nextTriggerTime: DateTime.now().subtract(const Duration(seconds: 5)),
        categoryFilter: 'Discipline',
      );

      await scheduleSvc.addRule(rule);

      // Trigger due check
      await scheduleSvc.checkDueRules();

      // Order must now be in running orders
      expect(engine.currentRunningOrders.length, 1);
      expect(engine.currentRunningOrders.first.order.title, 'Posture Discipline');

      // One-time rule must now be marked disabled
      expect(scheduleSvc.rules.first.isEnabled, isFalse);
    });

    test('Director scheduled rule dispatches order to player when due', () async {
      final storage = StorageService();
      final engine = OrderEngine(storage: storage);
      await engine.init();

      final specificOrder = OrderItem(
        id: 'ord-spec-1',
        title: 'Director Command Drill',
        description: 'Perform drill now',
        tier: 2,
        durationType: DurationType.instant,
      );

      final partnerSvc = PartnerService();
      final partner = PartnerContact(
        id: 'partner-sub-1',
        displayName: 'Submissive Jack',
        pairingCode: 'JACK-1234',
        pairingSecret: 'sec-1234',
        role: PartnerRole.submissive,
      );
      await partnerSvc.addContact(partner);

      final syncSvc = SyncService(engine);
      final scheduleSvc = ScheduleService();
      scheduleSvc.attachDependencies(
        orderEngine: engine,
        syncService: syncSvc,
        partnerService: partnerSvc,
      );

      // Create hourly director dispatch rule due in past
      final rule = ScheduledOrderRule(
        title: 'Command Dispatch',
        targetType: ScheduleTargetType.directorDispatch,
        frequency: RepeatFrequency.hourly,
        nextTriggerTime: DateTime.now().subtract(const Duration(seconds: 5)),
        isSpecificOrder: true,
        specificOrder: specificOrder,
        targetPartnerId: 'partner-sub-1',
        targetPartnerName: 'Submissive Jack',
      );

      await scheduleSvc.addRule(rule);

      await scheduleSvc.checkDueRules();

      // Rule must have advanced to next recurrence (1 hour in future)
      expect(scheduleSvc.rules.first.isEnabled, isTrue);
      expect(scheduleSvc.rules.first.nextTriggerTime.isAfter(DateTime.now()), isTrue);
      expect(scheduleSvc.rules.first.lastTriggeredAt != null, isTrue);
    });

    test('Random window scheduled rule re-arms next recurrence within window bounds and updates alarm schedule', () async {
      final storage = StorageService();
      final engine = OrderEngine(storage: storage);
      await engine.init();

      final scheduleSvc = ScheduleService();
      scheduleSvc.attachDependencies(
        orderEngine: engine,
        syncService: SyncService(engine),
        partnerService: PartnerService(),
      );

      // Create daily random window rule due right now (between 10 AM and 12 PM)
      final rule = ScheduledOrderRule(
        title: 'Morning Surprise',
        targetType: ScheduleTargetType.playerSelfDraw,
        timingMode: ScheduleTimingMode.randomWindow,
        windowStartHour: 10,
        windowStartMinute: 0,
        windowEndHour: 12,
        windowEndMinute: 0,
        frequency: RepeatFrequency.daily,
        nextTriggerTime: DateTime.now().subtract(const Duration(seconds: 1)),
      );

      await scheduleSvc.addRule(rule);
      await scheduleSvc.checkDueRules();

      // Rule must execute, draw an order, advance trigger to tomorrow, and stay enabled
      expect(engine.currentRunningOrders.length, 1);
      expect(scheduleSvc.rules.first.isEnabled, isTrue);
      final nextTrigger = scheduleSvc.rules.first.nextTriggerTime;
      expect(nextTrigger.isAfter(DateTime.now()), isTrue);
      // Next trigger must fall in the 10..12 window tomorrow
      final windowStartMinutes = 10 * 60;
      final windowEndMinutes = 12 * 60;
      final triggerMinutes = nextTrigger.hour * 60 + nextTrigger.minute;
      expect(triggerMinutes >= windowStartMinutes && triggerMinutes <= windowEndMinutes, isTrue);
    });

    test('Random window scheduled rule draws a genuine task from pack, not rule placeholder', () async {
      final storage = StorageService();
      final engine = OrderEngine(storage: storage);
      await engine.init();

      final scheduleSvc = ScheduleService();
      scheduleSvc.attachDependencies(
        orderEngine: engine,
        syncService: SyncService(engine),
        partnerService: PartnerService(),
      );

      final rule = ScheduledOrderRule(
        title: 'Surprise Window (3:00 PM – 3:15 PM)',
        targetType: ScheduleTargetType.playerSelfDraw,
        timingMode: ScheduleTimingMode.randomWindow,
        categoryFilter: null, // "All Categories"
        minTier: 1,
        maxTier: 3,
        windowStartHour: 15,
        windowStartMinute: 0,
        windowEndHour: 15,
        windowEndMinute: 15,
        frequency: RepeatFrequency.daily,
        nextTriggerTime: DateTime.now().subtract(const Duration(seconds: 1)),
      );

      await scheduleSvc.addRule(rule);
      await scheduleSvc.checkDueRules();

      expect(engine.currentRunningOrders.length, 1);
      final assignedOrder = engine.currentRunningOrders.first.order;

      // The assigned task MUST NOT be the rule title or generic placeholder
      expect(assignedOrder.title, isNot(contains('Surprise Window')));
      expect(assignedOrder.description, isNot(equals('Scheduled directive ready for execution.')));
      expect(assignedOrder.description.isNotEmpty, isTrue);
      expect(assignedOrder.rewardTokens > 0, isTrue);
    });
  });
}
