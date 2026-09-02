import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/order_pack.dart';
import 'package:orders_app/models/active_order.dart';

void main() {
  group('Model Serialization & Timing Tests', () {
    test('OrderItem json round-trip with action timer & deadline', () {
      final item = OrderItem(
        title: 'Morning Routine Drill',
        description: 'Perform 2 minute drill with vibrator.',
        category: 'Routine',
        tier: 2,
        durationType: DurationType.actionWithDeadline,
        actionDurationSeconds: 120,
        durationMinutes: 15,
        cooldownHours: 4,
        verificationType: VerificationType.honorCheck,
        rewardTokens: 15,
        penaltyTokens: 25,
        allowRandomDraw: false,
        requiredEquipment: ['Vibrator', 'Cage'],
      );

      final json = item.toJson();
      final reconstructed = OrderItem.fromJson(json);

      expect(reconstructed.id, equals(item.id));
      expect(reconstructed.title, equals(item.title));
      expect(reconstructed.category, equals(item.category));
      expect(reconstructed.tier, equals(2));
      expect(reconstructed.durationType, equals(DurationType.actionWithDeadline));
      expect(reconstructed.actionDurationSeconds, equals(120));
      expect(reconstructed.durationMinutes, equals(15));
      expect(reconstructed.allowRandomDraw, equals(false));
      expect(reconstructed.requiredEquipment, equals(['Vibrator', 'Cage']));
      expect(reconstructed.rewardTokens, equals(15));
    });

    test('OrderPack json round-trip with multiple items', () {
      final pack = OrderPack(
        title: 'Discipline Master Pack',
        description: 'Comprehensive accountability routines',
        author: 'Director Alpha',
        version: '1.2.0',
        tags: ['Discipline', 'Focus'],
        orders: [
          OrderItem(title: 'Task A', description: 'Desc A', tier: 1),
          OrderItem(title: 'Task B', description: 'Desc B', tier: 3),
        ],
      );

      final json = pack.toJson();
      final reconstructed = OrderPack.fromJson(json);

      expect(reconstructed.title, equals(pack.title));
      expect(reconstructed.author, equals('Director Alpha'));
      expect(reconstructed.orders.length, equals(2));
      expect(reconstructed.orders[0].title, equals('Task A'));
      expect(reconstructed.orders[1].title, equals('Task B'));
    });

    test('ActiveOrder deadline and action progress calculations', () {
      final orderItem = OrderItem(
        title: 'Timed Task',
        description: 'Desc',
        durationType: DurationType.actionWithDeadline,
        actionDurationSeconds: 120,
        durationMinutes: 10,
      );

      final now = DateTime.now();
      final active = ActiveOrder(
        order: orderItem,
        assignedAt: now,
        expiresAt: now.add(const Duration(minutes: 5)), // 5 mins left out of 10
        status: OrderStatus.active,
        actionSecondsRemaining: 60, // 60s left out of 120s
        isActionTimerRunning: true,
      );

      expect(active.isExpired, isFalse);
      expect(active.remainingSeconds, inInclusiveRange(290, 305));
      expect(active.deadlineProgressPercentage, inInclusiveRange(0.48, 0.52));
      expect(active.actionTimerProgressPercentage, equals(0.5));
    });

    test('VerificationType displayName returns clean user-facing labels', () {
      expect(VerificationType.honorCheck.displayName, equals('Honor'));
      expect(VerificationType.noteProof.displayName, equals('Note'));
      expect(VerificationType.photoProof.displayName, equals('Photo Proof'));
      expect(VerificationType.timerOnly.displayName, equals('Timer Only'));
    });
  });
}
