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

  group('Directive Recall Tombstoning & Deduplication Tests', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
    });

    test('toStateJson serializes ActiveOrder with proofImageBase64 set to null', () {
      final orderItem = OrderItem(
        id: 'drink_water_1',
        title: 'Drink 500ml Water',
        description: 'Stay hydrated',
        rewardTokens: 5,
      );

      final active = ActiveOrder(
        id: 'act_101',
        order: orderItem,
        status: OrderStatus.underReview,
        submissionProof: 'Done, here is proof',
        proofImageBase64: 'BASE64_VERY_LARGE_IMAGE_DATA_STRING_12345',
      );

      final fullJson = active.toJson();
      expect(fullJson['proofImageBase64'], 'BASE64_VERY_LARGE_IMAGE_DATA_STRING_12345');

      final stateJson = active.toStateJson();
      expect(stateJson['proofImageBase64'], isNull);
      expect(stateJson['id'], 'act_101');
      expect(stateJson['submissionProof'], 'Done, here is proof');
      expect(stateJson['status'], 'underReview');
    });

    test('Recalled directive is recorded in tombstone and not resurrected by incoming sendState', () async {
      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();

      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();

      final orderItem = OrderItem(
        id: 'wash_dishes_1',
        title: 'Wash Dishes',
        description: 'Clean all plates',
        rewardTokens: 10,
      );

      final activeOrder = ActiveOrder(
        id: 'act_wash_001',
        order: orderItem,
        assignedByDirector: true,
        assignedByPartnerCode: 'SUB123',
      );

      sync.remoteActiveOrders.add(activeOrder);
      expect(sync.remoteActiveOrders.length, 1);

      // Director recalls the order
      sync.recallDispatchedOrder(
        activeOrder.id,
        orderId: activeOrder.order.id,
        orderTitle: activeOrder.order.title,
      );

      expect(sync.remoteActiveOrders.isEmpty, isTrue);
      expect(sync.isOrderRecalled(activeOrder), isTrue);

      // Player later sends periodic sendState including this recalled order
      await sync.handleIncomingSyncMessage(SyncMessage(
        id: 'state_msg_1',
        type: SyncMessageType.sendState,
        senderId: 'player_device_1',
        payload: {
          'tokens': 20,
          'streak': 3,
          'activeOrders': [activeOrder.toJson()],
          'underReviewOrders': [],
          'senderCode': 'SUB123',
        },
      ));

      // Order MUST NOT resurrect in Director remoteActiveOrders
      expect(sync.remoteActiveOrders.isEmpty, isTrue);
    });

    test('Clearing an order from Director dashboard adds to tombstones and prevents resurrection', () async {
      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();

      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();

      final orderItem = OrderItem(
        id: 'stretch_1',
        title: 'Morning Stretch',
        description: '5 minute stretch',
        rewardTokens: 5,
      );

      final activeOrder = ActiveOrder(
        id: 'act_stretch_001',
        order: orderItem,
        assignedByDirector: true,
      );

      sync.remoteActiveOrders.add(activeOrder);
      expect(sync.remoteActiveOrders.length, 1);

      // Director clicks Clear (X) on active order card
      sync.clearRemoteActiveOrder(
        activeOrder.id,
        orderId: activeOrder.order.id,
        orderTitle: activeOrder.order.title,
      );

      expect(sync.remoteActiveOrders.isEmpty, isTrue);
      expect(sync.isOrderRecalled(activeOrder), isTrue);

      // Submissive device sends sendState
      await sync.handleIncomingSyncMessage(SyncMessage(
        id: 'state_msg_2',
        type: SyncMessageType.sendState,
        senderId: 'player_device_1',
        payload: {
          'tokens': 10,
          'streak': 1,
          'activeOrders': [activeOrder.toJson()],
          'underReviewOrders': [],
        },
      ));

      expect(sync.remoteActiveOrders.isEmpty, isTrue);
    });

    test('Duplicate active orders with identical title merge into exactly one entry', () async {
      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();

      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();

      final orderItem = OrderItem(
        id: 'reading_1',
        title: 'Read 10 Pages',
        description: 'Read a book',
        rewardTokens: 10,
      );

      // Card 1 on Director side
      final orderA = ActiveOrder(
        id: 'uuid_aaa',
        order: orderItem,
        assignedByDirector: true,
      );
      // Card 2 with different UUID but same title/order ID
      final orderB = ActiveOrder(
        id: 'uuid_bbb',
        order: orderItem,
        assignedByDirector: true,
      );

      sync.remoteActiveOrders.add(orderA);

      // Incoming sendState with orderB
      await sync.handleIncomingSyncMessage(SyncMessage(
        id: 'state_msg_dup',
        type: SyncMessageType.sendState,
        senderId: 'player_device_1',
        payload: {
          'tokens': 15,
          'streak': 2,
          'activeOrders': [orderA.toJson(), orderB.toJson()],
          'underReviewOrders': [],
        },
      ));

      // There must be exactly 1 card in remoteActiveOrders, NOT two
      expect(sync.remoteActiveOrders.length, 1);
      expect(sync.remoteActiveOrders.first.order.title, 'Read 10 Pages');
    });

    test('Periodic sendState preserves existing review proofImageBase64', () async {
      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();

      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();

      final orderItem = OrderItem(
        id: 'meditation_1',
        title: 'Daily Meditation',
        description: '10 mins mindful breathing',
        rewardTokens: 15,
      );

      // Initial submitProof message arrives with full proof image
      final reviewOrder = ActiveOrder(
        id: 'act_med_01',
        order: orderItem,
        status: OrderStatus.underReview,
        submissionProof: 'Meditated peacefully',
        proofImageBase64: 'ORIGINAL_IMAGE_DATA_BYTES_XYZ',
      );

      // Set Director role so submitProof is accepted
      sync.setAppRole(ConnectionRole.director);

      await sync.handleIncomingSyncMessage(SyncMessage(
        id: 'proof_msg_01',
        type: SyncMessageType.submitProof,
        senderId: 'player_device_1',
        payload: {
          'activeOrder': reviewOrder.toJson(),
          'senderCode': 'SUB456',
        },
      ));

      expect(sync.remoteReviewOrders.length, 1);
      expect(sync.remoteReviewOrders.first.proofImageBase64, 'ORIGINAL_IMAGE_DATA_BYTES_XYZ');

      // Now periodic sendState arrives from player using toStateJson() (proofImageBase64: null)
      final telemetryReview = reviewOrder.toStateJson();
      expect(telemetryReview['proofImageBase64'], isNull);

      await sync.handleIncomingSyncMessage(SyncMessage(
        id: 'state_msg_telemetry',
        type: SyncMessageType.sendState,
        senderId: 'player_device_1',
        payload: {
          'tokens': 30,
          'streak': 5,
          'activeOrders': [],
          'underReviewOrders': [telemetryReview],
        },
      ));

      // Director MUST still have the original image data preserved
      expect(sync.remoteReviewOrders.length, 1);
      expect(sync.remoteReviewOrders.first.proofImageBase64, 'ORIGINAL_IMAGE_DATA_BYTES_XYZ');
    });

    test('resendDispatchedOrder removes tombstone so deliberate resend is accepted', () async {
      final engine = OrderEngine();
      await engine.init();
      final partnerService = PartnerService();
      await partnerService.init();

      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init();

      final orderItem = OrderItem(
        id: 'exercise_1',
        title: '30 Pushups',
        description: 'Complete pushups',
        rewardTokens: 10,
      );

      final activeOrder = ActiveOrder(
        id: 'act_pushup_01',
        order: orderItem,
        assignedByDirector: true,
      );

      // Director recalls it
      sync.recallDispatchedOrder(
        activeOrder.id,
        orderId: activeOrder.order.id,
        orderTitle: activeOrder.order.title,
      );
      expect(sync.isOrderRecalled(activeOrder), isTrue);

      // Director intentionally re-sends it
      await sync.resendDispatchedOrder(activeOrder);

      // Tombstone MUST be removed
      expect(sync.isOrderRecalled(activeOrder), isFalse);
    });
  });
}
