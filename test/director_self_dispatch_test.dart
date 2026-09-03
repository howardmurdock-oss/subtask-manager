import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/active_order.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/models/quest_item.dart';
import 'package:orders_app/models/scheduled_order_rule.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/chat_service.dart';
import 'package:orders_app/services/quest_service.dart';
import 'package:orders_app/services/schedule_service.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/views/director/director_dashboard_view.dart';
import 'package:orders_app/views/director/order_dispatch_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Director Self Dispatch & Self Scheduling Tests', () {
    test('PartnerContact.self produces valid self-recipient model', () {
      final selfContact = PartnerContact.self();
      expect(selfContact.id, PartnerContact.selfId);
      expect(selfContact.isSelf, isTrue);
      expect(selfContact.displayName, 'Myself (This Device)');
    });

    test('PartnerService activePartner defaults to self when no contacts exist', () async {
      final partnerService = PartnerService();
      await partnerService.init();
      expect(partnerService.activePartner?.isSelf, isTrue);
      expect(partnerService.activePartner?.displayName, 'Myself (This Device)');

      final submissive = PartnerContact(id: 'sub_1', displayName: 'Sub Alex', pairingCode: 'ALEX123', pairingSecret: 'sec_alex');
      await partnerService.addContact(submissive);
      await partnerService.setActivePartner(submissive.id);
      expect(partnerService.activePartner?.displayName, 'Sub Alex');

      await partnerService.setActivePartner(PartnerContact.selfId);
      expect(partnerService.activePartner?.isSelf, isTrue);
      expect(partnerService.activePartner?.displayName, 'Myself (This Device)');

      partnerService.dispose();
    });

    test('SyncService dispatchOrderToPlayer with self recipient assigns locally', () async {
      final engine = OrderEngine();
      await engine.init();
      final sync = SyncService(engine);
      await sync.init();

      final order = OrderItem(
        id: 'ord_self_1',
        title: 'Cold Shower Protocol',
        description: 'Take a 2-minute ice cold shower',
        category: 'endurance',
        tier: 2,
        rewardTokens: 20,
        penaltyTokens: 10,
      );

      final dispatched = sync.dispatchOrderToPlayer(
        order,
        targetPartner: PartnerContact.self(),
      );

      expect(dispatched, isTrue);
      // Mounted on local engine running orders
      expect(engine.currentRunningOrders.length, 1);
      expect(engine.currentRunningOrders.first.order.title, 'Cold Shower Protocol');
      expect(engine.currentRunningOrders.first.assignedByDirector, isTrue);
      expect(engine.currentRunningOrders.first.assignedByPartnerId, PartnerContact.selfId);

      // Tracked under Director remote active queue
      expect(sync.remoteActiveOrders.length, 1);
      expect(sync.remoteActiveOrders.first.order.title, 'Cold Shower Protocol');

      // Marked confirmed on player device immediately
      expect(sync.isOrderConfirmedOnPlayer(sync.remoteActiveOrders.first), isTrue);

      sync.dispose();
      engine.dispose();
    });

    test('SyncService dispatchQuestToPlayer with self recipient assigns quest locally', () async {
      final engine = OrderEngine();
      await engine.init();
      final questService = QuestService();
      final sync = SyncService(engine);
      sync.attachServices(PartnerService(), ChatService(), questService: questService);
      await sync.init();

      final quest = Quest(
        id: 'quest_self_1',
        title: 'Morning Discipline Gauntlet',
        bonusTokensOnComplete: 30,
        steps: [
          QuestStep(orderIndex: 1, title: 'Hydrate 500ml', actionDurationSeconds: 60),
          QuestStep(orderIndex: 2, title: 'Plank Hold', actionDurationSeconds: 120),
        ],
      );

      final dispatched = sync.dispatchQuestToPlayer(
        quest,
        targetPartner: PartnerContact.self(),
      );

      expect(dispatched, isTrue);
      expect(questService.activeQuest?.quest.title, 'Morning Discipline Gauntlet');

      sync.dispose();
      engine.dispose();
    });

    test('ScheduleService automated director rule dispatches to self', () async {
      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();
      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();
      final scheduleService = ScheduleService();
      scheduleService.attachDependencies(
        orderEngine: engine,
        syncService: sync,
        partnerService: partnerService,
      );

      final specificOrder = OrderItem(
        id: 'ord_sched_self',
        title: 'Posture Discipline Check',
        description: 'Align spine against flat surface for 3 minutes',
      );

      final rule = ScheduledOrderRule(
        title: 'Daily Self Discipline',
        targetType: ScheduleTargetType.directorDispatch,
        timingMode: ScheduleTimingMode.specificTime,
        frequency: RepeatFrequency.daily,
        specificScheduledTime: DateTime.now().subtract(const Duration(minutes: 5)),
        nextTriggerTime: DateTime.now().subtract(const Duration(minutes: 1)),
        isSpecificOrder: true,
        specificOrder: specificOrder,
        targetPartnerId: PartnerContact.selfId,
        targetPartnerName: 'Myself (This Device)',
      );

      scheduleService.addRule(rule);
      await scheduleService.checkDueRules();

      // Verify dispatched to local queue
      expect(engine.currentRunningOrders.any((o) => o.order.title == 'Posture Discipline Check'), isTrue);

      scheduleService.dispose();
      sync.dispose();
      partnerService.dispose();
      engine.dispose();
    });

    testWidgets('DirectorDashboardView shows Active Submissive dropdown with Myself (This Device)', (tester) async {
      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();
      await partnerService.addContact(PartnerContact(id: 'sub_alex', displayName: 'Sub Alex', pairingCode: 'ALEX77', pairingSecret: 'sec_alex77'));
      partnerService.setActivePartner(PartnerContact.selfId);
      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: engine),
            ChangeNotifierProvider.value(value: sync),
            ChangeNotifierProvider.value(value: partnerService),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: DirectorDashboardView(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify "Active Submissive:" text and dropdown shows Myself (This Device)
      expect(find.text('Active Submissive:'), findsOneWidget);
      expect(find.text('Myself (This Device)'), findsOneWidget);

      await tester.pump(const Duration(seconds: 10));

      sync.dispose();
      partnerService.dispose();
      engine.dispose();
    });

    testWidgets('OrderDispatchDialog dispatches directly to active submissive (self)', (tester) async {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();
      partnerService.setActivePartner(PartnerContact.selfId);
      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();

      final order = OrderItem(
        id: 'ord_ui_dispatch',
        title: 'Deep Breathing Session',
        description: 'Inhale 4s, hold 4s, exhale 4s for 2 minutes',
        category: 'mindfulness',
        tier: 1,
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: engine),
            ChangeNotifierProvider.value(value: sync),
            ChangeNotifierProvider.value(value: partnerService),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: OrderDispatchDialog(initialOrder: order),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify subtitle indicates dispatching to yourself
      expect(find.text('Dispatching directive directly to yourself (This Device)'), findsOneWidget);

      // Find Dispatch Directive button
      final dispatchButton = find.widgetWithText(ElevatedButton, 'DISPATCH ORDER');
      expect(dispatchButton, findsOneWidget);
      await tester.ensureVisible(dispatchButton);
      await tester.tap(dispatchButton);
      await tester.pumpAndSettle();

      // Verify order mounted on local engine
      expect(engine.currentRunningOrders.any((o) => o.order.title == 'Deep Breathing Session'), isTrue);

      await tester.pump(const Duration(seconds: 10));

      sync.dispose();
      partnerService.dispose();
      engine.dispose();
    });

    testWidgets('OrderDispatchDialog allows selecting custom difficulty tier (e.g. Tier 4) on the spot', (tester) async {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();
      partnerService.setActivePartner(PartnerContact.selfId);
      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: engine),
            ChangeNotifierProvider.value(value: sync),
            ChangeNotifierProvider.value(value: partnerService),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: OrderDispatchDialog(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Switch to Custom Directive tab
      final customTab = find.text('Custom Directive');
      expect(customTab, findsOneWidget);
      await tester.tap(customTab);
      await tester.pumpAndSettle();

      // Enter title
      final titleField = find.widgetWithText(TextField, 'e.g. 20-Minute Room Cleanse');
      expect(titleField, findsOneWidget);
      await tester.enterText(titleField, 'Intense Kneeling Stance');

      // Select Tier 4 choice chip
      final t4Chip = find.widgetWithText(ChoiceChip, 'T4 - Intense');
      expect(t4Chip, findsOneWidget);
      await tester.ensureVisible(t4Chip);
      await tester.tap(t4Chip);
      await tester.pumpAndSettle();

      // Tap Dispatch button
      final dispatchButton = find.widgetWithText(ElevatedButton, 'DISPATCH ORDER');
      expect(dispatchButton, findsOneWidget);
      await tester.ensureVisible(dispatchButton);
      await tester.tap(dispatchButton);
      await tester.pumpAndSettle();

      // Verify order mounted on engine with tier 4
      final dispatched = engine.currentRunningOrders.firstWhere((o) => o.order.title == 'Intense Kneeling Stance');
      expect(dispatched.order.tier, equals(4));

      await tester.pump(const Duration(seconds: 10));

      sync.dispose();
      partnerService.dispose();
      engine.dispose();
    });

    testWidgets('DirectorDashboardView only displays commands sent by this director and hides others', (tester) async {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();

      final submissive = PartnerContact(
        id: 'sub_alex',
        displayName: 'Sub Alex',
        pairingCode: 'ALEX77',
        pairingSecret: 'sec_alex77',
      );
      await partnerService.addContact(submissive);
      await partnerService.setActivePartner(submissive.id);

      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();
      sync.setPairingCode('MYDIR_A');

      // Create orders:
      // 1. Sent by THIS director (MYDIR_A)
      final myOrder = ActiveOrder(
        id: 'ord_my_dir',
        order: OrderItem(id: 'item_1', title: 'Director A Command', description: 'Do task A'),
        assignedByDirector: true,
        assignedByPartnerCode: 'MYDIR_A',
      );

      // 2. Sent by ANOTHER director (OTHER_DIR)
      final otherDirectorOrder = ActiveOrder(
        id: 'ord_other_dir',
        order: OrderItem(id: 'item_2', title: 'Director B Secret Command', description: 'Do task B'),
        assignedByDirector: true,
        assignedByPartnerCode: 'OTHER_DIR',
      );

      // 3. Self-drawn by player on their own device
      final playerSelfOrder = ActiveOrder(
        id: 'ord_player_self',
        order: OrderItem(id: 'item_3', title: 'Player Self Drawn Habit', description: 'Do personal habit'),
        assignedByDirector: false,
      );

      // Simulate state received from Submissive's device with all 3 orders
      await sync.handleIncomingSyncMessage(SyncMessage(
        type: SyncMessageType.sendState,
        senderId: 'sub_alex',
        payload: {
          'activeOrders': [
            myOrder.toJson(),
            otherDirectorOrder.toJson(),
            playerSelfOrder.toJson(),
          ],
        },
      ));

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: engine),
            ChangeNotifierProvider.value(value: sync),
            ChangeNotifierProvider.value(value: partnerService),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: DirectorDashboardView(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify ONLY Director A's command is displayed on Director A's dashboard
      expect(find.text('Director A Command'), findsOneWidget);

      // Verify other Director's command and player self-drawn order are HIDDEN
      expect(find.text('Director B Secret Command'), findsNothing);
      expect(find.text('Player Self Drawn Habit'), findsNothing);

      await tester.pump(const Duration(seconds: 10));

      sync.dispose();
      partnerService.dispose();
      engine.dispose();
    });
  });
}
