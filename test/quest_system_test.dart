import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/quest_item.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/services/quest_service.dart';
import 'package:orders_app/services/order_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Quest Models & Serialization Tests', () {
    test('QuestStep JSON round-trip serialization', () {
      final step = QuestStep(
        orderIndex: 1,
        title: 'Hydrate & Posture',
        description: 'Stand at attention for 120s',
        narrativeText: 'Yield to the discipline.',
        durationType: DurationType.actionTimer,
        actionDurationSeconds: 120,
        rewardTokens: 10,
        verificationType: VerificationType.honorCheck,
        requiredEquipment: ['Posture Collar'],
        isHiddenUntilUnlocked: true,
      );

      final json = step.toJson();
      final roundTrip = QuestStep.fromJson(json);

      expect(roundTrip.id, equals(step.id));
      expect(roundTrip.title, equals('Hydrate & Posture'));
      expect(roundTrip.narrativeText, equals('Yield to the discipline.'));
      expect(roundTrip.durationType, equals(DurationType.actionTimer));
      expect(roundTrip.actionDurationSeconds, equals(120));
      expect(roundTrip.rewardTokens, equals(10));
      expect(roundTrip.requiredEquipment, contains('Posture Collar'));
      expect(roundTrip.isHiddenUntilUnlocked, isTrue);
    });

    test('Quest JSON round-trip serialization with multiple steps', () {
      final quest = Quest(
        title: 'Evening Gauntlet',
        description: 'Multi-step evening obedience playlist.',
        category: 'Evening Routine',
        bonusTokensOnComplete: 50,
        steps: [
          QuestStep(orderIndex: 1, title: 'Step 1: Stance', rewardTokens: 5),
          QuestStep(orderIndex: 2, title: 'Step 2: Silence', rewardTokens: 10),
          QuestStep(orderIndex: 3, title: 'Step 3: Verification', rewardTokens: 15),
        ],
      );

      final json = quest.toJson();
      final roundTrip = Quest.fromJson(json);

      expect(roundTrip.id, equals(quest.id));
      expect(roundTrip.title, equals('Evening Gauntlet'));
      expect(roundTrip.steps.length, equals(3));
      expect(roundTrip.bonusTokensOnComplete, equals(50));
      expect(roundTrip.totalPotentialTokens, equals(80)); // 5 + 10 + 15 + 50
    });

    test('ActiveQuest tracks step progress and completion fraction', () {
      final quest = Quest(
        title: 'Trial',
        steps: [
          QuestStep(orderIndex: 1, title: 'Step 1'),
          QuestStep(orderIndex: 2, title: 'Step 2'),
        ],
      );

      final active = ActiveQuest(quest: quest);
      expect(active.currentStepIndex, equals(0));
      expect(active.progressFraction, equals(0.0));
      expect(active.isCompleted, isFalse);

      // Simulate first step completion
      active.stepProgress[0] = ActiveQuestStepProgress(stepId: quest.steps[0].id, isCompleted: true);
      active.currentStepIndex = 1;

      expect(active.completedStepsCount, equals(1));
      expect(active.progressFraction, equals(0.5));
      expect(active.currentStep?.title, equals('Step 2'));
    });

    test('OrderItem to QuestStep conversion retains timing and parameters', () {
      final order = OrderItem(
        title: 'Deep Breathing Focus',
        description: 'Breathe in for 4s, hold for 4s, exhale for 4s.',
        category: 'Focus',
        durationType: DurationType.actionTimer,
        actionDurationSeconds: 180,
        durationMinutes: 3,
        rewardTokens: 15,
        verificationType: VerificationType.honorCheck,
        requiredEquipment: ['Blindfold'],
      );

      final step = QuestStep(
        orderIndex: 1,
        title: order.title,
        description: order.description,
        durationType: order.durationType,
        durationMinutes: order.durationMinutes,
        actionDurationSeconds: order.actionDurationSeconds,
        rewardTokens: order.rewardTokens,
        verificationType: order.verificationType,
        requiredEquipment: List.from(order.requiredEquipment),
      );

      expect(step.title, equals(order.title));
      expect(step.description, equals(order.description));
      expect(step.durationType, equals(DurationType.actionTimer));
      expect(step.actionDurationSeconds, equals(180));
      expect(step.rewardTokens, equals(15));
      expect(step.requiredEquipment, contains('Blindfold'));
    });
  });

  group('QuestService Patreon Gating & Progression Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('Patreon passcode gating: unlocks on valid code and rejects invalid', () async {
      final service = QuestService();
      await Future.delayed(const Duration(milliseconds: 50));

      expect(service.isUnlocked, isFalse);

      // Invalid passcode
      final failResult = service.unlockWithPasscode('WRONG-CODE');
      expect(failResult, isFalse);
      expect(service.isUnlocked, isFalse);

      // Valid passcode (case-insensitive, whitespace-trimmed)
      final successResult = service.unlockWithPasscode('  patreon-vip  ');
      expect(successResult, isTrue);
      expect(service.isUnlocked, isTrue);

      // Relock
      service.relock();
      expect(service.isUnlocked, isFalse);

      // Alternate valid code
      expect(service.unlockWithPasscode('QUESTS-2026'), isTrue);
      expect(service.isUnlocked, isTrue);
    });

    test('Quest progression awards step tokens and grand completion bonus', () async {
      final engine = OrderEngine();
      await engine.init();
      final initialTokens = engine.stats.tokens;

      final questSvc = QuestService();
      await Future.delayed(const Duration(milliseconds: 50));

      final testQuest = Quest(
        title: 'Unit Test Protocol',
        bonusTokensOnComplete: 20,
        steps: [
          QuestStep(orderIndex: 1, title: 'Step 1', rewardTokens: 5),
          QuestStep(orderIndex: 2, title: 'Step 2', rewardTokens: 10),
        ],
      );

      questSvc.startQuest(testQuest);
      expect(questSvc.activeQuest, isNotNull);
      expect(questSvc.activeQuest!.currentStepIndex, equals(0));

      // Complete Step 1
      await questSvc.completeCurrentStep(engine: engine);
      expect(engine.stats.tokens, equals(initialTokens + 5));
      expect(questSvc.activeQuest!.currentStepIndex, equals(1));
      expect(questSvc.activeQuest!.isCompleted, isFalse);

      // Complete Step 2 (Final step -> should award step tokens + completion bonus)
      await questSvc.completeCurrentStep(engine: engine);
      expect(engine.stats.tokens, equals(initialTokens + 5 + 10 + 20));
      expect(questSvc.activeQuest!.isCompleted, isTrue);
      expect(questSvc.completedQuestsHistory.length, equals(1));
    });

    test('QuestService can create, edit, update, and delete custom quests', () async {
      final questSvc = QuestService();

      final quest = Quest(
        id: 'custom-quest-edit-1',
        title: 'Original Title',
        description: 'Original description',
        category: 'Discipline',
        bonusTokensOnComplete: 30,
        steps: [
          QuestStep(orderIndex: 1, title: 'Original Step 1', rewardTokens: 5),
        ],
      );

      await questSvc.saveCustomQuest(quest);
      expect(questSvc.customQuests.length, 1);
      expect(questSvc.customQuests.first.title, 'Original Title');

      // Edit the existing quest
      final updatedQuest = Quest(
        id: 'custom-quest-edit-1',
        title: 'Edited Quest Title',
        description: 'Updated comprehensive instructions',
        category: 'Advanced Focus',
        bonusTokensOnComplete: 50,
        steps: [
          QuestStep(orderIndex: 1, title: 'Edited Step 1', rewardTokens: 10),
          QuestStep(orderIndex: 2, title: 'New Added Step 2', rewardTokens: 15),
        ],
      );

      await questSvc.saveCustomQuest(updatedQuest);
      expect(questSvc.customQuests.length, 1);
      final saved = questSvc.customQuests.first;
      expect(saved.title, 'Edited Quest Title');
      expect(saved.description, 'Updated comprehensive instructions');
      expect(saved.category, 'Advanced Focus');
      expect(saved.bonusTokensOnComplete, 50);
      expect(saved.steps.length, 2);
      expect(saved.totalPotentialTokens, 75); // 10 + 15 + 50

      // Delete custom quest
      await questSvc.deleteCustomQuest('custom-quest-edit-1');
      expect(questSvc.customQuests.length, 0);
    });

    test('Customizing a preset quest overrides it in allQuests library', () async {
      final questSvc = QuestService();
      final preset = questSvc.presetQuests.first;

      final customizedPreset = Quest(
        id: preset.id,
        title: '${preset.title} (Customized)',
        description: 'Customized description by director',
        category: preset.category,
        bonusTokensOnComplete: 100,
        steps: preset.steps,
      );

      await questSvc.saveCustomQuest(customizedPreset);

      final matching = questSvc.allQuests.firstWhere((q) => q.id == preset.id);
      expect(matching.title, '${preset.title} (Customized)');
      expect(matching.bonusTokensOnComplete, 100);
    });
  });

  group('SyncMessage Quest Types Tests', () {
    test('dispatchQuest and questStepCompleted sync message serialization', () {
      final quest = Quest(
        title: 'Synced Quest',
        steps: [QuestStep(orderIndex: 1, title: 'Step A')],
      );

      final msg = SyncMessage(
        type: SyncMessageType.dispatchQuest,
        senderId: 'dir-123',
        payload: {
          'quest': quest.toJson(),
          'senderName': 'Director Master',
        },
      );

      final encoded = msg.encode();
      final decoded = SyncMessage.decode(encoded);

      expect(decoded.type, equals(SyncMessageType.dispatchQuest));
      expect(decoded.senderId, equals('dir-123'));
      expect(decoded.payload['senderName'], equals('Director Master'));
      final decodedQuest = Quest.fromJson(Map<String, dynamic>.from(decoded.payload['quest'] as Map));
      expect(decodedQuest.title, equals('Synced Quest'));
    });
  });
}
