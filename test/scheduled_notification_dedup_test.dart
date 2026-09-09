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

/// A scheduled occurrence is announced twice: once by the pre-armed OS alarm at
/// its trigger time, and again by whichever isolate then executes the rule —
/// which is typically woken *by* that very alarm. One task, two notifications.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Occurrence announcement bookkeeping', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('an occurrence the alarm covers is not announced twice', () async {
      final trigger = DateTime(2026, 5, 4, 15, 12);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(NotificationService.announcedKey,
          [NotificationService.announceKey('rule-a', trigger)]);

      expect(
          await NotificationService.wasOccurrenceAnnounced('rule-a', trigger),
          isTrue);
    });

    test('an unrelated occurrence is still free to announce', () async {
      final trigger = DateTime(2026, 5, 4, 15, 12);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(NotificationService.announcedKey,
          [NotificationService.announceKey('rule-a', trigger)]);

      expect(
          await NotificationService.wasOccurrenceAnnounced('rule-b', trigger),
          isFalse);
      expect(
          await NotificationService.wasOccurrenceAnnounced(
              'rule-a', trigger.add(const Duration(days: 1))),
          isFalse);
    });

    test('nothing recorded means the executor must still announce', () async {
      expect(
          await NotificationService.wasOccurrenceAnnounced(
              'rule-a', DateTime(2026, 5, 4, 15, 12)),
          isFalse,
          reason: 'a silent task is worse than a duplicated notification');
    });

    test('announce keys ignore sub-minute drift from JSON round-tripping', () {
      expect(
        NotificationService.announceKey('r', DateTime(2026, 5, 4, 9, 30, 12, 500)),
        NotificationService.announceKey('r', DateTime(2026, 5, 4, 9, 30, 47, 10)),
      );
    });

    test('the announce key matches the scheduling ledger key', () {
      // Both sides must agree on what "one occurrence" means, or suppression
      // would silently target the wrong firing.
      final t = DateTime(2026, 5, 4, 15, 12, 33);
      expect(NotificationService.announceKey('rule-x', t),
          ScheduleCoordinator.occurrenceKey('rule-x', t));
    });
  });

  group('Execution still delivers the order', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('a task whose alarm already fired is still mounted, just silently',
        () async {
      final storage = StorageService();
      await storage.savePacks([
        OrderPack(
          id: 'pack-1',
          title: 'Pack',
          description: 'One task',
          author: 'Director',
          orders: [
            OrderItem(
              id: 'ord-1',
              title: 'The Task',
              description: 'Do it',
              category: 'Discipline',
              tier: 1,
              rewardTokens: 10,
            ),
          ],
        ),
      ]);

      final engine = OrderEngine(storage: storage);
      await engine.init();

      final trigger = DateTime.now().subtract(const Duration(minutes: 30));
      final rule = ScheduledOrderRule(
        id: 'rule-announced',
        title: 'Surprise Window',
        targetType: ScheduleTargetType.playerSelfDraw,
        frequency: RepeatFrequency.once,
        nextTriggerTime: trigger,
        categoryFilter: 'Discipline',
      );

      // Stand in for the alarm having already announced this firing.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(NotificationService.announcedKey,
          [NotificationService.announceKey(rule.id, trigger)]);

      final schedule = ScheduleService();
      await schedule.init();
      schedule.attachDependencies(
        orderEngine: engine,
        syncService: SyncService(engine),
        partnerService: PartnerService(),
      );
      await schedule.addRule(rule);
      await schedule.checkDueRules();

      // Suppressing the notification must not suppress the task itself.
      expect(engine.currentRunningOrders.length, 1);
      expect(engine.currentRunningOrders.first.order.title, 'The Task');
      expect(engine.currentRunningOrders.first.assignedAt, trigger,
          reason: 'the true trigger time must survive the catch-up');
    });
  });
}
