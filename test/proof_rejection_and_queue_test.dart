import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/active_order.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Proof Submission & Queue Segregation Tests', () {
    test('Order under review exits currentRunningOrders and is only in underReviewOrders', () async {
      final storage = StorageService();
      final engine = OrderEngine(storage: storage);
      await engine.init();

      final order = OrderItem(
        id: 'ord-review-1',
        title: 'Posture Discipline Drill',
        description: 'Sit upright',
        category: 'Discipline',
        tier: 1,
        durationType: DurationType.instant,
        verificationType: VerificationType.photoProof,
        rewardTokens: 10,
        penaltyTokens: 5,
      );

      final activeOrder = engine.assignOrder(order);

      expect(engine.currentRunningOrders.length, 1);
      expect(engine.underReviewOrders.length, 0);

      // Player submits proof
      engine.submitOrCompleteOrder(activeOrder.id, proofNote: 'Photo taken', proofImageBase64: 'fake-base64');

      // Must exit running orders and only be in underReviewOrders
      expect(engine.currentRunningOrders.length, 0);
      expect(engine.underReviewOrders.length, 1);
      expect(engine.underReviewOrders.first.status, OrderStatus.underReview);
      expect(engine.underReviewOrders.first.submissionProof, 'Photo taken');
      expect(engine.underReviewOrders.first.proofImageBase64, 'fake-base64');
    });

    test('Reject and Penalize terminates task, deducts penalty tokens, and logs failure', () async {
      final storage = StorageService();
      final engine = OrderEngine(storage: storage);
      await engine.init();

      final order = OrderItem(
        id: 'ord-penalize-1',
        title: 'Calisthenics Check',
        description: 'Perform pushups',
        category: 'Physical',
        tier: 2,
        durationType: DurationType.instant,
        verificationType: VerificationType.photoProof,
        rewardTokens: 20,
        penaltyTokens: 15,
      );

      final activeOrder = engine.assignOrder(order);
      engine.submitOrCompleteOrder(activeOrder.id, proofNote: 'Bad attempt');

      expect(engine.underReviewOrders.length, 1);

      // Director rejects and penalizes
      engine.rejectProof(activeOrder.id, reason: 'Form incorrect', penalize: true);

      // Must NOT be in running or review orders
      expect(engine.currentRunningOrders.length, 0);
      expect(engine.underReviewOrders.length, 0);
      expect(engine.failedOrders.length, 1);
      expect(engine.failedOrders.first.status, OrderStatus.failed);
      expect(engine.failedOrders.first.directorNote, 'Form incorrect');
      expect(engine.stats.totalFailed, 1);
      expect(engine.stats.history.first.tokenDelta, -15);
    });

    test('Reject and Return resets proof, timers, and restores order to active queue with 0 penalty', () async {
      final storage = StorageService();
      final engine = OrderEngine(storage: storage);
      await engine.init();

      final order = OrderItem(
        id: 'ord-return-1',
        title: 'Timed Wall Sit',
        description: 'Hold for 60 seconds',
        category: 'Endurance',
        tier: 2,
        durationType: DurationType.actionTimer,
        actionDurationSeconds: 60,
        verificationType: VerificationType.photoProof,
        rewardTokens: 25,
        penaltyTokens: 10,
      );

      final activeOrder = engine.assignOrder(order);
      engine.submitOrCompleteOrder(activeOrder.id, proofNote: 'Finished early', proofImageBase64: 'img-data');

      expect(engine.underReviewOrders.length, 1);
      expect(engine.currentRunningOrders.length, 0);

      final initialTokens = engine.stats.tokens;
      // Director rejects and returns to queue
      engine.returnProofToQueue(activeOrder.id, reason: 'Angle too dark, retake photo');

      // Order must be back in currentRunningOrders with status active
      expect(engine.underReviewOrders.length, 0);
      expect(engine.currentRunningOrders.length, 1);
      expect(engine.failedOrders.length, 0);

      final restored = engine.currentRunningOrders.first;
      expect(restored.status, OrderStatus.active);
      expect(restored.submissionProof, isNull);
      expect(restored.proofImageBase64, isNull);
      expect(restored.directorNote, 'Angle too dark, retake photo');
      expect(restored.actionSecondsRemaining, 60);
      expect(restored.isActionTimerFinished, isFalse);
      expect(restored.isActionTimerRunning, isFalse);

      // Token count must not be penalized
      expect(engine.stats.tokens, initialTokens);
      expect(engine.stats.totalFailed, 0);
    });
  });

  group('SyncService Proof Rejection Sync Tests', () {
    test('SyncService handles rejectProof with returnToQueue = true', () async {
      final storage = StorageService();
      final engine = OrderEngine(storage: storage);
      await engine.init();

      final sync = SyncService(engine);

      final order = OrderItem(
        id: 'ord-sync-return',
        title: 'Discipline Task',
        description: 'Stand tall',
        category: 'Discipline',
        tier: 1,
        durationType: DurationType.instant,
        verificationType: VerificationType.noteProof,
        rewardTokens: 10,
        penaltyTokens: 5,
      );

      final active = engine.assignOrder(order);
      engine.submitOrCompleteOrder(active.id, proofNote: 'Done');
      expect(engine.underReviewOrders.length, 1);

      // Simulate incoming rejectProof message with returnToQueue: true
      final msg = SyncMessage(
        id: 'msg-rej-1',
        type: SyncMessageType.rejectProof,
        senderId: 'director-1',
        payload: {
          'activeOrderId': active.id,
          'reason': 'Please add more detail to your note',
          'returnToQueue': true,
        },
      );

      await sync.handleIncomingSyncMessage(msg);

      expect(engine.underReviewOrders.length, 0);
      expect(engine.currentRunningOrders.length, 1);
      expect(engine.currentRunningOrders.first.status, OrderStatus.active);
      expect(engine.currentRunningOrders.first.submissionProof, isNull);
      expect(engine.currentRunningOrders.first.directorNote, 'Please add more detail to your note');
      expect(engine.stats.totalFailed, 0);
    });

    test('SyncService handles rejectProof with returnToQueue = false (Penalize)', () async {
      final storage = StorageService();
      final engine = OrderEngine(storage: storage);
      await engine.init();

      final sync = SyncService(engine);

      final order = OrderItem(
        id: 'ord-sync-pen',
        title: 'Demanding Task',
        description: 'Do 50 squats',
        category: 'Physical',
        tier: 3,
        durationType: DurationType.instant,
        verificationType: VerificationType.photoProof,
        rewardTokens: 30,
        penaltyTokens: 20,
      );

      final active = engine.assignOrder(order);
      engine.submitOrCompleteOrder(active.id, proofNote: 'Failed attempt');
      expect(engine.underReviewOrders.length, 1);

      // Simulate incoming rejectProof message with returnToQueue: false
      final msg = SyncMessage(
        id: 'msg-rej-2',
        type: SyncMessageType.rejectProof,
        senderId: 'director-1',
        payload: {
          'activeOrderId': active.id,
          'reason': 'Did not complete required reps',
          'returnToQueue': false,
        },
      );

      await sync.handleIncomingSyncMessage(msg);

      expect(engine.underReviewOrders.length, 0);
      expect(engine.currentRunningOrders.length, 0);
      expect(engine.failedOrders.length, 1);
      expect(engine.failedOrders.first.status, OrderStatus.failed);
      expect(engine.failedOrders.first.directorNote, 'Did not complete required reps');
      expect(engine.stats.totalFailed, 1);
    });
  });
}
