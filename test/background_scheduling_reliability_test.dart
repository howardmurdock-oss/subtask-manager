import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/core/notifications/notification_service.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/order_pack.dart';
import 'package:orders_app/models/scheduled_order_rule.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/schedule_coordinator.dart';
import 'package:orders_app/services/schedule_service.dart';
import 'package:orders_app/services/storage_service.dart';
import 'package:orders_app/services/sync_service.dart';

/// Regression coverage for scheduled orders going missing after the app has sat
/// in the background on Android for a long time.
///
/// The failures these lock down all came from the UI isolate and the
/// `flutter_foreground_task` background isolate having independent
/// SharedPreferences caches and no agreement about who had run what.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  OrderItem task(String id, String title) => OrderItem(
        id: id,
        title: title,
        description: 'Do the thing',
        category: 'Discipline',
        tier: 1,
        rewardTokens: 10,
        durationType: DurationType.instant,
      );

  Future<StorageService> storageWithSingleTask() async {
    final storage = StorageService();
    await storage.savePacks([
      OrderPack(
        id: 'pack-solo',
        title: 'Solo Pack',
        description: 'Exactly one drawable task',
        author: 'Director',
        orders: [task('ord-solo', 'The Only Task')],
      ),
    ]);
    return storage;
  }

  ScheduledOrderRule dueRule({
    required String id,
    required String title,
    OrderItem? staged,
    RepeatFrequency frequency = RepeatFrequency.once,
    Duration overdueBy = const Duration(minutes: 5),
  }) {
    return ScheduledOrderRule(
      id: id,
      title: title,
      targetType: ScheduleTargetType.playerSelfDraw,
      frequency: frequency,
      nextTriggerTime: DateTime.now().subtract(overdueBy),
      categoryFilter: 'Discipline',
      stagedOrder: staged,
    );
  }

  group('Multiple due rules all reach the dashboard', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('three rules due at once each mount their own active order', () async {
      final storage = StorageService();
      await storage.savePacks([
        OrderPack(
          id: 'pack-multi',
          title: 'Multi',
          description: 'Several tasks',
          author: 'Director',
          orders: [
            task('ord-a', 'Task A'),
            task('ord-b', 'Task B'),
            task('ord-c', 'Task C'),
          ],
        ),
      ]);
      final engine = OrderEngine(storage: storage);
      await engine.init();

      final schedule = ScheduleService();
      await schedule.init();
      schedule.attachDependencies(
        orderEngine: engine,
        syncService: SyncService(engine),
        partnerService: PartnerService(),
      );

      await schedule.addRule(dueRule(
          id: 'r1', title: 'Rule One', staged: task('ord-a', 'Task A')));
      await schedule.addRule(dueRule(
          id: 'r2', title: 'Rule Two', staged: task('ord-b', 'Task B')));
      await schedule.addRule(dueRule(
          id: 'r3', title: 'Rule Three', staged: task('ord-c', 'Task C')));

      await schedule.checkDueRules();

      expect(engine.currentRunningOrders.length, 3);
    });

    test('two rules that draw the identical task both mount', () async {
      // A small pack means separate rules routinely draw the same task. Folding
      // those together on title alone silently lost the second order.
      final storage = await storageWithSingleTask();
      final engine = OrderEngine(storage: storage);
      await engine.init();

      final schedule = ScheduleService();
      await schedule.init();
      schedule.attachDependencies(
        orderEngine: engine,
        syncService: SyncService(engine),
        partnerService: PartnerService(),
      );

      await schedule.addRule(dueRule(id: 'same-1', title: 'Morning Window'));
      await schedule.addRule(dueRule(id: 'same-2', title: 'Evening Window'));

      await schedule.checkDueRules();

      expect(engine.currentRunningOrders.length, 2);
      expect(
        engine.currentRunningOrders.map((o) => o.order.title).toSet(),
        {'The Only Task'},
      );
      // Distinct occurrences, so distinct active-order ids.
      expect(engine.currentRunningOrders.map((o) => o.id).toSet().length, 2);
    });

    test('overlapping checkDueRules passes assign the order only once', () async {
      final storage = await storageWithSingleTask();
      final engine = OrderEngine(storage: storage);
      await engine.init();

      final schedule = ScheduleService();
      await schedule.init();
      schedule.attachDependencies(
        orderEngine: engine,
        syncService: SyncService(engine),
        partnerService: PartnerService(),
      );

      await schedule.addRule(dueRule(id: 'reentrant', title: 'Reentrant Rule'));

      // The 10s ticker, app resume, notification tap and startup can all land
      // in the same moment.
      await Future.wait([
        schedule.checkDueRules(),
        schedule.checkDueRules(),
        schedule.checkDueRules(),
      ]);

      expect(engine.currentRunningOrders.length, 1);
    });
  });

  group('Cross-isolate occurrence ledger', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('a firing already delivered by the background isolate is not repeated',
        () async {
      final trigger = DateTime.now().subtract(const Duration(hours: 2));
      final rule = ScheduledOrderRule(
        id: 'rule-bg-done',
        title: 'Already Delivered',
        targetType: ScheduleTargetType.playerSelfDraw,
        frequency: RepeatFrequency.daily,
        specificScheduledTime: trigger,
        nextTriggerTime: trigger,
        stagedOrder: task('ord-bg', 'Background Task'),
      );

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'saved_scheduled_rules_v1', jsonEncode([rule.toJson()]));
      // Stand in for the background isolate having already run this firing.
      await prefs.setStringList(ScheduleCoordinator.ledgerKey,
          [ScheduleCoordinator.occurrenceKey('rule-bg-done', trigger)]);

      final storage = await storageWithSingleTask();
      final engine = OrderEngine(storage: storage);
      await engine.init();

      final schedule = ScheduleService();
      await schedule.init();
      schedule.attachDependencies(
        orderEngine: engine,
        syncService: SyncService(engine),
        partnerService: PartnerService(),
      );
      await schedule.resyncFromStorage();

      expect(engine.currentRunningOrders, isEmpty,
          reason: 'the occurrence was already claimed');
      // The schedule must still move on rather than staying stuck in the past.
      final updated = schedule.rules.firstWhere((r) => r.id == 'rule-bg-done');
      expect(updated.nextTriggerTime.isAfter(DateTime.now()), isTrue);
    });

    test('claimOccurrence is granted exactly once', () async {
      final prefs = await SharedPreferences.getInstance();
      const key = 'rule-x@20260101T0900';

      expect(await ScheduleCoordinator.claimOccurrence(prefs, key), isTrue);
      expect(await ScheduleCoordinator.claimOccurrence(prefs, key), isFalse);
      expect(await ScheduleCoordinator.claimOccurrence(prefs, 'rule-x@20260102T0900'),
          isTrue);
    });

    test('occurrence key ignores sub-second drift from JSON round-tripping', () {
      final a = DateTime(2026, 5, 4, 9, 30, 12, 500);
      final b = DateTime(2026, 5, 4, 9, 30, 47, 10);
      expect(ScheduleCoordinator.occurrenceKey('r', a),
          equals(ScheduleCoordinator.occurrenceKey('r', b)));
    });
  });

  group('Resync does not roll back background progress', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('rules advanced on disk while the UI isolate slept are not overwritten',
        () async {
      final storage = await storageWithSingleTask();
      final engine = OrderEngine(storage: storage);
      await engine.init();

      final schedule = ScheduleService();
      await schedule.init();
      schedule.attachDependencies(
        orderEngine: engine,
        syncService: SyncService(engine),
        partnerService: PartnerService(),
      );

      final future = DateTime.now().add(const Duration(hours: 6));
      await schedule.addRule(ScheduledOrderRule(
        id: 'rule-advanced',
        title: 'Nightly',
        targetType: ScheduleTargetType.playerSelfDraw,
        frequency: RepeatFrequency.daily,
        nextTriggerTime: DateTime.now().add(const Duration(hours: 1)),
      ));

      // Background isolate advances the rule directly on disk.
      final prefs = await SharedPreferences.getInstance();
      final onDisk = (jsonDecode(prefs.getString('saved_scheduled_rules_v1')!)
              as List)
          .map((r) => ScheduledOrderRule.fromJson(Map<String, dynamic>.from(r as Map)))
          .toList();
      await prefs.setString(
        'saved_scheduled_rules_v1',
        jsonEncode([onDisk.first.copyWith(nextTriggerTime: future).toJson()]),
      );

      await schedule.resyncFromStorage();

      final reloaded = schedule.rules.firstWhere((r) => r.id == 'rule-advanced');
      expect(reloaded.nextTriggerTime.isAfter(
          DateTime.now().add(const Duration(hours: 5))), isTrue);
    });
  });

  group('Catch-up after a long sleep', () {
    test('a missed daily rule still fires on its next scheduled day', () {
      // Rule was due yesterday 08:00 and the device only woke at 07:00 today.
      // Computing "tomorrow" from now would skip today's 08:00 as well.
      final now = DateTime(2026, 3, 10, 7, 0);
      final rule = ScheduledOrderRule(
        id: 'daily-missed',
        title: 'Morning Drill',
        targetType: ScheduleTargetType.playerSelfDraw,
        frequency: RepeatFrequency.daily,
        specificScheduledTime: DateTime(2026, 3, 9, 8, 0),
        nextTriggerTime: DateTime(2026, 3, 9, 8, 0),
      );

      expect(rule.computeNextRecurrenceAfter(now), DateTime(2026, 3, 10, 8, 0));
    });

    test('hourly rules keep their original minute instead of drifting', () {
      final rule = ScheduledOrderRule(
        id: 'hourly',
        title: 'Hourly Check',
        targetType: ScheduleTargetType.playerSelfDraw,
        frequency: RepeatFrequency.hourly,
        nextTriggerTime: DateTime(2026, 3, 9, 8, 0),
      );

      // Caught up three and a half hours late.
      final next = rule.computeNextRecurrenceAfter(DateTime(2026, 3, 9, 11, 30));
      expect(next, DateTime(2026, 3, 9, 12, 0));
    });

    test('weekly rules keep their day of week', () {
      final anchor = DateTime(2026, 3, 2, 19, 0); // a Monday
      final rule = ScheduledOrderRule(
        id: 'weekly',
        title: 'Weekly Ritual',
        targetType: ScheduleTargetType.playerSelfDraw,
        frequency: RepeatFrequency.weekly,
        specificScheduledTime: anchor,
        nextTriggerTime: anchor,
      );

      final next = rule.computeNextRecurrenceAfter(DateTime(2026, 3, 12, 12, 0));
      expect(next, DateTime(2026, 3, 16, 19, 0));
      expect(next!.weekday, anchor.weekday);
    });

    test('one-time rules never reschedule', () {
      final rule = ScheduledOrderRule(
        id: 'once',
        title: 'One Shot',
        targetType: ScheduleTargetType.playerSelfDraw,
        frequency: RepeatFrequency.once,
        nextTriggerTime: DateTime(2026, 3, 9, 8, 0),
      );
      expect(rule.computeNextRecurrenceAfter(DateTime(2026, 3, 12)), isNull);
    });
  });

  group('Background hand-off queue', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Map<String, dynamic> queuedOrder(String activeId, String title) => {
          'type': 'dispatchOrder',
          'isScheduled': true,
          'activeOrderId': activeId,
          'order': task('ord-$activeId', title).toJson(),
          'senderName': 'Scheduled Task',
          'senderId': '__self__',
          'senderCode': '',
          'assignedByDirector': false,
          'assignedAt':
              DateTime.now().subtract(const Duration(minutes: 20)).toIso8601String(),
        };

    test('every queued background order mounts, including same-titled ones',
        () async {
      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();
      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('pending_background_orders_v1', [
        jsonEncode(queuedOrder('sched_one', 'Repeated Task')),
        jsonEncode(queuedOrder('sched_two', 'Repeated Task')),
        jsonEncode(queuedOrder('sched_three', 'A Different Task')),
      ]);

      await sync.processPendingBackgroundMessages();

      expect(engine.activeOrders.length, 3);
      expect(engine.activeOrders.map((o) => o.id).toSet(),
          {'sched_one', 'sched_two', 'sched_three'});
    });

    test('draining removes only the entries the pass handled', () async {
      // A drain reads a snapshot of the queue, then deletes. If it clears the
      // whole key it also throws away whatever the background isolate appended
      // in between — an order that is then gone for good.
      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();
      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();

      final prefs = await SharedPreferences.getInstance();
      final handled = jsonEncode(queuedOrder('sched_handled', 'Handled Task'));
      final arrivedLate = jsonEncode(queuedOrder('sched_late', 'Late Task'));

      await prefs.setStringList(
          'pending_background_orders_v1', [handled, arrivedLate]);

      // The pass only saw `handled`; `arrivedLate` landed after its snapshot.
      await sync.consumeQueuedEntries('pending_background_orders_v1', [handled]);

      expect(prefs.getStringList('pending_background_orders_v1'),
          equals([arrivedLate]));
    });

    test('draining clears the key once nothing is left queued', () async {
      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();
      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();

      final prefs = await SharedPreferences.getInstance();
      final only = jsonEncode(queuedOrder('sched_only', 'Only Task'));
      await prefs.setStringList('pending_background_orders_v1', [only]);

      await sync.processPendingBackgroundMessages();

      expect(prefs.getStringList('pending_background_orders_v1'), isNull);
      expect(engine.activeOrders.single.id, 'sched_only');
    });
  });

  group('Pre-armed alarm window', () {
    // Arming only the next occurrence meant a recurring rule notified once and
    // then went silent, because nothing re-arms the chain while the process is
    // dead. These lock down the look-ahead that keeps it announcing itself.
    test('a daily rule arms a run of consecutive days', () {
      final rule = ScheduledOrderRule(
        id: 'daily-window',
        title: 'Morning Drill',
        targetType: ScheduleTargetType.playerSelfDraw,
        frequency: RepeatFrequency.daily,
        specificScheduledTime: DateTime(2026, 4, 1, 8, 0),
        nextTriggerTime: DateTime(2026, 4, 1, 8, 0),
      );

      final triggers =
          rule.upcomingTriggers(5, from: DateTime(2026, 3, 31, 22, 0));

      expect(triggers, [
        DateTime(2026, 4, 1, 8, 0),
        DateTime(2026, 4, 2, 8, 0),
        DateTime(2026, 4, 3, 8, 0),
        DateTime(2026, 4, 4, 8, 0),
        DateTime(2026, 4, 5, 8, 0),
      ]);
    });

    test('an overdue recurring rule arms from the next future occurrence', () {
      final rule = ScheduledOrderRule(
        id: 'overdue',
        title: 'Missed Drill',
        targetType: ScheduleTargetType.playerSelfDraw,
        frequency: RepeatFrequency.daily,
        specificScheduledTime: DateTime(2026, 4, 1, 8, 0),
        nextTriggerTime: DateTime(2026, 4, 1, 8, 0),
      );

      // Device slept through three days; it is now the 4th at lunchtime.
      final triggers =
          rule.upcomingTriggers(3, from: DateTime(2026, 4, 4, 12, 0));

      expect(triggers, [
        DateTime(2026, 4, 5, 8, 0),
        DateTime(2026, 4, 6, 8, 0),
        DateTime(2026, 4, 7, 8, 0),
      ]);
      expect(triggers.every((t) => t.isAfter(DateTime(2026, 4, 4, 12, 0))),
          isTrue);
    });

    test('a one-shot rule arms exactly one occurrence', () {
      final rule = ScheduledOrderRule(
        id: 'one-shot',
        title: 'Single',
        targetType: ScheduleTargetType.playerSelfDraw,
        frequency: RepeatFrequency.once,
        nextTriggerTime: DateTime(2026, 4, 1, 8, 0),
      );

      expect(rule.upcomingTriggers(5, from: DateTime(2026, 3, 31)).length, 1);
    });

    test('a one-shot rule whose moment has passed arms nothing', () {
      final rule = ScheduledOrderRule(
        id: 'one-shot-gone',
        title: 'Single',
        targetType: ScheduleTargetType.playerSelfDraw,
        frequency: RepeatFrequency.once,
        nextTriggerTime: DateTime(2026, 4, 1, 8, 0),
      );

      expect(rule.upcomingTriggers(5, from: DateTime(2026, 4, 2)), isEmpty);
    });

    test('random-window occurrences each land inside the window', () {
      final rule = ScheduledOrderRule(
        id: 'rand-window',
        title: 'Surprise',
        targetType: ScheduleTargetType.playerSelfDraw,
        timingMode: ScheduleTimingMode.randomWindow,
        frequency: RepeatFrequency.daily,
        windowStartHour: 15,
        windowStartMinute: 0,
        windowEndHour: 21,
        windowEndMinute: 0,
        nextTriggerTime: DateTime(2026, 4, 1, 17, 0),
      );

      final triggers =
          rule.upcomingTriggers(5, from: DateTime(2026, 4, 1, 9, 0));

      expect(triggers.length, 5);
      for (final t in triggers) {
        final minutes = t.hour * 60 + t.minute;
        expect(minutes, inInclusiveRange(15 * 60, 21 * 60),
            reason: '$t fell outside the 15:00-21:00 window');
      }
      // Strictly increasing, one per day — no duplicates or backwards steps.
      for (var i = 1; i < triggers.length; i++) {
        expect(triggers[i].isAfter(triggers[i - 1]), isTrue);
      }
    });

    test('the armed window never exceeds the requested count', () {
      final rule = ScheduledOrderRule(
        id: 'hourly-many',
        title: 'Hourly',
        targetType: ScheduleTargetType.playerSelfDraw,
        frequency: RepeatFrequency.hourly,
        nextTriggerTime: DateTime(2026, 4, 1, 8, 0),
      );

      expect(
          rule
              .upcomingTriggers(NotificationService.preArmedOccurrences,
                  from: DateTime(2026, 4, 1, 7, 0))
              .length,
          NotificationService.preArmedOccurrences);
    });
  });

  group('Notification identity', () {
    test('rule alarm ids are stable and distinct per rule', () {
      // A per-run id would leave the previous alarm uncancellable, stacking a
      // duplicate every time a rule re-arms.
      const ruleId = '6f3c1b9e-2a44-4f77-9c0e-1d2e3f4a5b6c';
      expect(
        ScheduleCoordinator.activeOrderIdFor(ruleId, DateTime(2026, 1, 1, 9)),
        isNot(ScheduleCoordinator.activeOrderIdFor(ruleId, DateTime(2026, 1, 2, 9))),
      );
      expect(
        ScheduleCoordinator.activeOrderIdFor(ruleId, DateTime(2026, 1, 1, 9)),
        ScheduleCoordinator.activeOrderIdFor(ruleId, DateTime(2026, 1, 1, 9)),
      );
    });
  });
}
