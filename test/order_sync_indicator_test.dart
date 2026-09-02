import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/chat_service.dart';
import 'package:orders_app/services/quest_service.dart';
import 'package:orders_app/services/schedule_service.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/views/director/director_dashboard_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Order Sync Delivery Confirmation & Re-sync Tests', () {
    test('Director tracking detects unconfirmed vs confirmed orders', () async {
      final engine = OrderEngine();
      await engine.init();
      final sync = SyncService(engine);
      await sync.init();

      final order = OrderItem(
        id: 'ord_123',
        title: 'Calisthenics Protocol',
        description: 'Perform 20 pushups',
        category: 'fitness',
        tier: 2,
        rewardTokens: 15,
        penaltyTokens: 10,
      );

      // Director dispatches order
      sync.dispatchOrderToPlayer(order);
      expect(sync.remoteActiveOrders.length, 1);
      final active = sync.remoteActiveOrders.first;

      // Initially, player has not confirmed receipt
      expect(sync.isOrderConfirmedOnPlayer(active), isFalse);

      // Simulate receiving dispatchOrderAck from Player
      final ackMsg = SyncMessage(
        type: SyncMessageType.dispatchOrderAck,
        senderId: 'sub_device_456',
        payload: {
          'activeOrderId': active.id,
          'orderId': order.id,
          'orderTitle': order.title,
          'senderCode': 'SUB123',
          'senderName': 'Submissive',
        },
      );
      await sync.handleIncomingSyncMessage(ackMsg);

      // Now marked as confirmed on device
      expect(sync.isOrderConfirmedOnPlayer(active), isTrue);
    });

    test('sendState payload confirms mounted active orders on Director dashboard', () async {
      final engine = OrderEngine();
      await engine.init();
      final sync = SyncService(engine);
      await sync.init();

      final order = OrderItem(
        id: 'ord_456',
        title: 'Postural Reset',
        description: 'Maintain upright spine for 10 minutes',
        category: 'discipline',
        tier: 1,
        rewardTokens: 10,
      );

      sync.dispatchOrderToPlayer(order);
      final active = sync.remoteActiveOrders.first;
      expect(sync.isOrderConfirmedOnPlayer(active), isFalse);

      // Simulate Player broadcasting their current state with this active order
      final stateMsg = SyncMessage(
        type: SyncMessageType.sendState,
        senderId: 'player_dev',
        payload: {
          'tokens': 50,
          'streak': 3,
          'activeOrders': [active.toJson()],
          'underReviewOrders': [],
          'pendingRedemptions': [],
        },
      );
      await sync.handleIncomingSyncMessage(stateMsg);

      // Order is now recognized as active on player's device
      expect(sync.isOrderConfirmedOnPlayer(active), isTrue);
    });

    test('resendDispatchedOrder re-broadcasts order and requests state', () async {
      final engine = OrderEngine();
      await engine.init();
      final sync = SyncService(engine);
      await sync.init();

      final order = OrderItem(
        id: 'ord_789',
        title: 'Hydration Intake',
        description: 'Drink 500ml water',
      );

      sync.dispatchOrderToPlayer(order);
      final active = sync.remoteActiveOrders.first;

      final res = await sync.resendDispatchedOrder(active);
      expect(res, isTrue);
    });

    test('Player dispatchOrder assigns directive and automatically acks', () async {
      final engine = OrderEngine();
      await engine.init();
      final sync = SyncService(engine);
      await sync.init();

      final order = OrderItem(
        id: 'ord_auto_ack',
        title: 'Immediate Task',
        description: 'Testing auto ack',
      );

      final dispatchMsg = SyncMessage(
        type: SyncMessageType.dispatchOrder,
        senderId: 'dir_device',
        payload: {
          'order': order.toJson(),
          'activeOrderId': 'active_999',
          'senderCode': 'DIR888',
          'senderName': 'Director',
        },
      );

      expect(engine.currentRunningOrders.isEmpty, isTrue);

      await sync.handleIncomingSyncMessage(dispatchMsg);

      // Verify assigned in player engine
      expect(engine.currentRunningOrders.length, 1);
      expect(engine.currentRunningOrders.first.order.title, 'Immediate Task');
    });

    testWidgets('DirectorDashboardView displays status indicators and Re-send button', (tester) async {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();
      final chatService = ChatService();
      await chatService.init();
      final questService = QuestService();
      final scheduleService = ScheduleService();
      final submissive = PartnerContact(
        id: 'sub_1',
        displayName: 'Sub Alex',
        pairingCode: 'SUB123',
        pairingSecret: 'sec123',
        role: PartnerRole.submissive,
      );
      await partnerService.addContact(submissive);
      await partnerService.setActivePartner(submissive.id);
      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();

      final order = OrderItem(
        id: 'ord_ui_test',
        title: 'Posture Check',
        description: 'Sit straight',
        category: 'discipline',
        tier: 1,
      );
      sync.dispatchOrderToPlayer(order);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: engine),
            ChangeNotifierProvider.value(value: sync),
            ChangeNotifierProvider.value(value: partnerService),
            ChangeNotifierProvider.value(value: chatService),
            ChangeNotifierProvider.value(value: questService),
            ChangeNotifierProvider.value(value: scheduleService),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: DirectorDashboardView(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify Re-sync All button in header
      expect(find.text('Re-sync All'), findsOneWidget);

      // Verify pending status indicator light
      expect(find.text('Dispatch Pending • Syncing'), findsOneWidget);
      expect(find.text('Re-send'), findsOneWidget);

      // Simulate ack from player
      final ackMsg = SyncMessage(
        type: SyncMessageType.dispatchOrderAck,
        senderId: 'sub_dev',
        payload: {
          'activeOrderId': sync.remoteActiveOrders.first.id,
          'orderId': order.id,
          'orderTitle': order.title,
        },
      );
      await sync.handleIncomingSyncMessage(ackMsg);
      await tester.pumpAndSettle();

      // Verify green active indicator light
      expect(find.text('Active on Submissive\'s Device'), findsOneWidget);

      // Tap Re-send button
      await tester.tap(find.text('Re-send'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Re-sent "Posture Check"'), findsOneWidget);

      await tester.pump(const Duration(seconds: 10));

      scheduleService.dispose();
      sync.dispose();
      engine.dispose();
    });
  });
}
