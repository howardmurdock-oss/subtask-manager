import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/active_order.dart';
import 'package:orders_app/models/sync_message.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Emergency Clear, Status Indication & Re-Send Tests', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
    });

    test('Player emergency clear notifies Director and marks directive as emergencyCleared on Director dashboard', () async {
      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();

      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();

      final orderItem = OrderItem(
        id: 'clean_desk_01',
        title: 'Clear Desk Completely',
        description: 'Remove all clutter from desk surface',
        rewardTokens: 10,
      );

      final activeOrder = ActiveOrder(
        id: 'ord_active_123',
        order: orderItem,
        assignedByDirector: true,
        assignedByPartnerCode: 'DIR100',
        assignedByPartnerId: 'director_device_1',
      );

      // Director holds the dispatched active order
      sync.remoteActiveOrders.add(activeOrder);
      await sync.handleIncomingSyncMessage(SyncMessage(
        id: 'ack_001',
        type: SyncMessageType.dispatchOrderAck,
        senderId: 'player_device_1',
        payload: {
          'activeOrderId': activeOrder.id,
          'orderId': activeOrder.order.id,
          'orderTitle': activeOrder.order.title,
          'status': 'received',
        },
      ));
      expect(sync.isOrderConfirmedOnPlayer(activeOrder), isTrue);

      // Player emergency clears this directive
      final clearMsg = SyncMessage(
        id: 'msg_clear_001',
        type: SyncMessageType.orderStatusUpdate,
        senderId: 'player_device_1',
        payload: {
          'activeOrderId': 'ord_active_123',
          'orderId': 'clean_desk_01',
          'orderTitle': 'Clear Desk Completely',
          'status': 'emergencyCleared',
          'reason': 'Emergency Cleared by Player Alex',
          'senderName': 'Player Alex',
        },
      );

      await sync.handleIncomingSyncMessage(clearMsg);

      // Verify Director''s remoteActiveOrders card is updated to emergencyCleared
      final directorCard = sync.remoteActiveOrders.firstWhere((o) => o.id == 'ord_active_123');
      expect(directorCard.status, equals(OrderStatus.emergencyCleared));
      expect(directorCard.directorNote, contains('Emergency Cleared by Player Alex'));
      expect(sync.isOrderConfirmedOnPlayer(directorCard), isFalse);
    });

    test('sendState reconciliation automatically marks missing active directives as emergencyCleared', () async {
      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();

      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();

      final orderItem = OrderItem(
        id: 'posture_check_01',
        title: 'Posture Check',
        description: 'Sit straight for 15 minutes',
        rewardTokens: 10,
      );

      final activeOrder = ActiveOrder(
        id: 'ord_active_456',
        order: orderItem,
        assignedByDirector: true,
        assignedByPartnerCode: 'DIR100',
      );

      // Director had this order confirmed on the player
      sync.remoteActiveOrders.add(activeOrder);
      await sync.handleIncomingSyncMessage(SyncMessage(
        id: 'ack_002',
        type: SyncMessageType.dispatchOrderAck,
        senderId: 'player_device_1',
        payload: {
          'activeOrderId': activeOrder.id,
          'orderId': activeOrder.order.id,
          'orderTitle': activeOrder.order.title,
          'status': 'received',
        },
      ));
      expect(sync.isOrderConfirmedOnPlayer(activeOrder), isTrue);

      // Player sends state with an empty active orders list (they emergency-cleared it)
      final stateMsg = SyncMessage(
        id: 'msg_state_001',
        type: SyncMessageType.sendState,
        senderId: 'player_device_1',
        payload: {
          'activeOrders': <Map<String, dynamic>>[],
          'underReviewOrders': <Map<String, dynamic>>[],
          'tokens': 50,
          'streak': 3,
        },
      );

      await sync.handleIncomingSyncMessage(stateMsg);

      // Reconciliation should have updated the order to emergencyCleared
      final directorCard = sync.remoteActiveOrders.firstWhere((o) => o.id == 'ord_active_456');
      expect(directorCard.status, equals(OrderStatus.emergencyCleared));
      expect(directorCard.directorNote, equals('Emergency Cleared by Submissive'));
      expect(sync.isOrderConfirmedOnPlayer(directorCard), isFalse);
    });

    test('Re-sending an emergency cleared directive resets Director status and successfully mounts on Player', () async {
      // 1. Setup Director environment
      final directorEngine = OrderEngine();
      await directorEngine.init();
      final directorPartnerSvc = PartnerService();
      await directorPartnerSvc.init();
      final directorSync = SyncService(directorEngine, partnerService: directorPartnerSvc);
      await directorSync.init();

      final orderItem = OrderItem(
        id: 'pushups_resend_01',
        title: 'Pushups Required',
        description: 'Drop and do 25 pushups',
        rewardTokens: 20,
      );

      final directorCard = ActiveOrder(
        id: 'active_pushups_777',
        order: orderItem,
        status: OrderStatus.emergencyCleared,
        directorNote: 'Emergency Cleared by Submissive',
        assignedByDirector: true,
      );
      directorSync.remoteActiveOrders.add(directorCard);

      // 2. Setup Player environment
      final playerEngine = OrderEngine();
      await playerEngine.init();
      final playerPartnerSvc = PartnerService();
      await playerPartnerSvc.init();
      final playerSync = SyncService(playerEngine, partnerService: playerPartnerSvc);
      await playerSync.init();

      // Pre-mark the directive in player''s handled ledger as if it had previously existed
      playerSync.markDirectiveHandled(
        activeOrderId: 'active_pushups_777',
        orderId: 'pushups_resend_01',
        msgId: 'old_msg_001',
        title: 'Pushups Required',
      );
      expect(playerSync.isDirectiveHandled(activeOrderId: 'active_pushups_777'), isTrue);
      expect(playerEngine.activeOrders.isEmpty, isTrue);

      // 3. Director taps Re-send
      await directorSync.resendDispatchedOrder(directorCard);

      // Verify Director local card reset back to active and cleared directorNote
      final updatedDirectorCard = directorSync.remoteActiveOrders.firstWhere((o) => o.id == 'active_pushups_777');
      expect(updatedDirectorCard.status, equals(OrderStatus.active));
      expect(updatedDirectorCard.directorNote, isNull);

      // 4. Player receives the re-sent packet (with isResend: true)
      final resendMsg = SyncMessage(
        id: 'msg_resend_001',
        type: SyncMessageType.dispatchOrder,
        senderId: 'director_device_1',
        payload: {
          'activeOrderId': 'active_pushups_777',
          'order': orderItem.toJson(),
          'senderCode': 'DIR100',
          'senderName': 'Director Sovereign',
          'isResend': true,
          'forceAssign': true,
        },
      );

      await playerSync.handleIncomingSyncMessage(resendMsg);

      // Verify player engine now HAS the directive active!
      expect(playerEngine.activeOrders.length, equals(1));
      expect(playerEngine.activeOrders.first.id, equals('active_pushups_777'));
      expect(playerEngine.activeOrders.first.order.title, equals('Pushups Required'));
    });

    test('clearAllFailedRemoteOrders cleans up both failed and emergencyCleared directives', () async {
      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();

      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();

      final order1 = ActiveOrder(
        id: 'ord_1',
        order: OrderItem(title: 'T1', description: 'D1'),
        status: OrderStatus.failed,
      );
      final order2 = ActiveOrder(
        id: 'ord_2',
        order: OrderItem(title: 'T2', description: 'D2'),
        status: OrderStatus.emergencyCleared,
      );
      final order3 = ActiveOrder(
        id: 'ord_3',
        order: OrderItem(title: 'T3', description: 'D3'),
        status: OrderStatus.active,
      );

      sync.remoteActiveOrders.addAll([order1, order2, order3]);
      for (final o in [order1, order2, order3]) {
        await sync.handleIncomingSyncMessage(SyncMessage(
          id: 'ack_${o.id}',
          type: SyncMessageType.dispatchOrderAck,
          senderId: 'player_device_1',
          payload: {
            'activeOrderId': o.id,
            'orderId': o.order.id,
            'orderTitle': o.order.title,
            'status': 'received',
          },
        ));
      }

      sync.clearAllFailedRemoteOrders();

      expect(sync.remoteActiveOrders.length, equals(1));
      expect(sync.remoteActiveOrders.first.id, equals('ord_3'));
      expect(sync.confirmedOnPlayerOrderIds.contains('ord_1'), isFalse);
      expect(sync.confirmedOnPlayerOrderIds.contains('ord_2'), isFalse);
      expect(sync.confirmedOnPlayerOrderIds.contains('ord_3'), isTrue);
    });

    test('notifyDirectiveEmergencyCleared removes directive from handled ledger', () async {
      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();

      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();

      final orderItem = OrderItem(
        id: 'cardio_01',
        title: 'Morning Run',
        description: 'Run 2 miles',
      );

      final activeOrder = ActiveOrder(
        id: 'run_active_1',
        order: orderItem,
        assignedByDirector: true,
      );

      sync.markDirectiveHandled(
        activeOrderId: 'run_active_1',
        orderId: 'cardio_01',
        msgId: 'msg_1',
        title: 'Morning Run',
      );
      expect(sync.isDirectiveHandled(activeOrderId: 'run_active_1'), isTrue);

      await sync.notifyDirectiveEmergencyCleared(activeOrder);

      // Handled ledger should no longer block this directive
      expect(sync.isDirectiveHandled(activeOrderId: 'run_active_1'), isFalse);
    });
  });
}
