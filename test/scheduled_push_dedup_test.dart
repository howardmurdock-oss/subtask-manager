import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/core/security/encryption_helper.dart';
import 'package:orders_app/models/active_order.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/order_pack.dart';
import 'package:orders_app/models/scheduled_order_rule.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/schedule_coordinator.dart';
import 'package:orders_app/services/schedule_service.dart';
import 'package:orders_app/services/storage_service.dart';
import 'package:orders_app/services/sync_service.dart';

/// Scheduled occurrences are now fired from two independent places: the local
/// alarm on the device, and a Cloudflare cron pushing a pre-staged directive.
/// That redundancy is deliberate — neither is reliable alone — but it is only
/// safe if the two cannot both mount the same occurrence.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const myCode = 'PLAYER1';
  const mySecret = 'SHARED_SECRET';
  const ruleId = 'rule-window';

  setUp(() => SharedPreferences.setMockInitialValues({}));

  OrderItem task() => OrderItem(
        id: 'ord_task',
        title: 'Surprise Task',
        description: 'Do the thing',
        category: 'Discipline',
        tier: 1,
        rewardTokens: 10,
      );

  /// Exactly what ScheduleService stages with the Worker for one occurrence.
  String stagedPayloadFor(DateTime trigger) {
    final msg = SyncMessage(
      id: 'sched_${ScheduleCoordinator.occurrenceKey(ruleId, trigger)}',
      type: SyncMessageType.dispatchOrder,
      // Must not be this device's id or code: _isOwnMessage would discard it
      // as an echo, which is exactly the bug this fixture caught.
      senderId: 'scheduled',
      targetCode: myCode,
      payload: {
        'activeOrderId': ScheduleCoordinator.activeOrderIdFor(ruleId, trigger),
        'order': task().toJson(),
        'senderCode': '',
        'senderName': 'Scheduled Task',
        'assignedByDirector': false,
        'isScheduled': true,
        'assignedAt': trigger.toIso8601String(),
      },
    );
    return EncryptionHelper.encryptString(msg.encode(), mySecret);
  }

  Future<(SyncService, OrderEngine, ScheduleService)> device() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pairing_code', myCode);
    await prefs.setString('pairing_secret', mySecret);

    final storage = StorageService();
    await storage.savePacks([
      OrderPack(
        id: 'pack',
        title: 'Pack',
        description: 'One task',
        author: 'Director',
        orders: [task()],
      ),
    ]);

    final engine = OrderEngine(storage: storage);
    await engine.init();
    final partners = PartnerService();
    await partners.init();
    final sync = SyncService(engine, partnerService: partners);
    await sync.init(deferNetwork: true);
    final schedule = ScheduleService();
    await schedule.init();
    schedule.attachDependencies(
      orderEngine: engine,
      syncService: sync,
      partnerService: partners,
    );
    return (sync, engine, schedule);
  }

  test('a pushed scheduled directive mounts once, and the local rule does not double it',
      () async {
    final (sync, engine, schedule) = await device();
    final trigger = DateTime.now().subtract(const Duration(minutes: 5));

    // The cron fired first: the pre-staged directive arrives by push.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        'pending_background_push_v1', [stagedPayloadFor(trigger)]);
    await sync.processPendingBackgroundMessages();

    expect(engine.activeOrders.length, 1);
    final mountedId = engine.activeOrders.first.id;
    expect(mountedId, ScheduleCoordinator.activeOrderIdFor(ruleId, trigger));

    // Now the device wakes and runs the same occurrence locally.
    await schedule.addRule(ScheduledOrderRule(
      id: ruleId,
      title: 'Surprise Window',
      targetType: ScheduleTargetType.playerSelfDraw,
      frequency: RepeatFrequency.daily,
      nextTriggerTime: trigger,
      categoryFilter: 'Discipline',
      stagedOrder: task(),
    ));
    await schedule.checkDueRules();

    expect(engine.activeOrders.length, 1,
        reason: 'the same occurrence must not mount twice');
    expect(engine.activeOrders.first.id, mountedId);
  });

  test('the local rule still fires when no push arrived', () async {
    // The redundancy must not depend on the push having happened.
    final (_, engine, schedule) = await device();
    final trigger = DateTime.now().subtract(const Duration(minutes: 5));

    await schedule.addRule(ScheduledOrderRule(
      id: ruleId,
      title: 'Surprise Window',
      targetType: ScheduleTargetType.playerSelfDraw,
      frequency: RepeatFrequency.daily,
      nextTriggerTime: trigger,
      categoryFilter: 'Discipline',
      stagedOrder: task(),
    ));
    await schedule.checkDueRules();

    expect(engine.activeOrders.length, 1);
    expect(engine.activeOrders.first.id,
        ScheduleCoordinator.activeOrderIdFor(ruleId, trigger));
  });

  test('a later occurrence of the same rule is a different directive', () async {
    // Deduping must key on the occurrence, not the rule, or tomorrow's task
    // would be swallowed as a duplicate of today's.
    final today = DateTime(2026, 5, 4, 11, 20);
    final tomorrow = DateTime(2026, 5, 5, 11, 20);

    expect(ScheduleCoordinator.activeOrderIdFor(ruleId, today),
        isNot(ScheduleCoordinator.activeOrderIdFor(ruleId, tomorrow)));
  });

  test('a pushed scheduled self-draw is self-assigned, so it runs on honour', () async {
    // Mounting it as director-assigned hid the self-verify option and routed
    // submitted proof to the first contact in the list.
    final (sync, engine, _) = await device();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('pending_background_push_v1',
        [stagedPayloadFor(DateTime.now().subtract(const Duration(minutes: 1)))]);
    await sync.processPendingBackgroundMessages();

    expect(engine.activeOrders.single.assignedByDirector, isFalse);
  });

  test('scheduled tasks mounted as director-assigned by older builds are repaired', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    await storage.saveActiveOrders([
      ActiveOrder(
        id: 'sched_stuck',
        order: task(),
        assignedAt: DateTime.now(),
        status: OrderStatus.underReview,
        assignedByDirector: true,
        assignedByPartnerId: 'scheduled',
        assignedByPartnerName: 'Scheduled Task',
      ),
      ActiveOrder(
        id: 'real_director',
        order: task(),
        assignedAt: DateTime.now(),
        status: OrderStatus.active,
        assignedByDirector: true,
        assignedByPartnerId: 'partner-1',
        assignedByPartnerName: 'Director',
      ),
    ]);

    final engine = OrderEngine(storage: storage);
    await engine.init();

    final byId = {for (final o in engine.activeOrders) o.id: o};
    expect(byId['sched_stuck']!.assignedByDirector, isFalse);
    expect(byId['sched_stuck']!.status, OrderStatus.underReview,
        reason: 'left in review, but now completable by the player');
    expect(byId['real_director']!.assignedByDirector, isTrue,
        reason: 'a real director assignment is untouched');
  });
}
