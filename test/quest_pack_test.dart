import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/quest_item.dart';
import 'package:orders_app/models/quest_pack.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/services/quest_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('QuestPack Model Tests', () {
    test('QuestPack serialization and deserialization preserves all fields', () {
      final step1 = QuestStep(
        orderIndex: 1,
        title: 'Calisthenics Induction',
        description: 'Perform 20 pushups',
        durationType: DurationType.actionTimer,
        actionDurationSeconds: 120,
        rewardTokens: 10,
      );

      final step2 = QuestStep(
        orderIndex: 2,
        title: 'Meditation & Focus',
        description: 'Remain still for 5 minutes',
        durationType: DurationType.actionTimer,
        actionDurationSeconds: 300,
        rewardTokens: 15,
      );

      final quest = Quest(
        id: 'q-test-1',
        title: 'Morning Discipline Protocol',
        description: 'A 2-step morning routine',
        category: 'Discipline',
        bonusTokensOnComplete: 20,
        steps: [step1, step2],
      );

      final pack = QuestPack(
        id: 'pack-test-1',
        title: 'Daily Gauntlets',
        description: 'A collection of routine protocols',
        author: 'Master Director',
        version: '1.2.0',
        tags: ['Discipline', 'Daily'],
        quests: [quest],
      );

      expect(pack.totalStepsCount, 2);
      expect(pack.totalPotentialTokens, 45); // 10 + 15 + 20

      final json = pack.toJson();
      final restored = QuestPack.fromJson(json);

      expect(restored.id, 'pack-test-1');
      expect(restored.title, 'Daily Gauntlets');
      expect(restored.description, 'A collection of routine protocols');
      expect(restored.author, 'Master Director');
      expect(restored.version, '1.2.0');
      expect(restored.tags, contains('Discipline'));
      expect(restored.quests.length, 1);
      expect(restored.quests.first.title, 'Morning Discipline Protocol');
      expect(restored.quests.first.steps.length, 2);
      expect(restored.quests.first.steps[0].rewardTokens, 10);
      expect(restored.quests.first.steps[1].rewardTokens, 15);
    });

    test('QuestPack.fromSingleQuest creates a valid single-quest pack', () {
      final quest = Quest(
        id: 'single-q',
        title: 'Focus Drill',
        description: 'Single quest',
        category: 'Mental',
        bonusTokensOnComplete: 10,
        steps: [
          QuestStep(orderIndex: 1, title: 'Read Chapter', durationType: DurationType.instant, rewardTokens: 5),
        ],
      );

      final pack = QuestPack.fromSingleQuest(quest, author: 'Trainer');

      expect(pack.title, 'Focus Drill');
      expect(pack.description, 'Single quest');
      expect(pack.author, 'Trainer');
      expect(pack.quests.length, 1);
      expect(pack.totalStepsCount, 1);
      expect(pack.totalPotentialTokens, 15);
    });
  });

  group('QuestService QuestPack Storage & Import/Export Tests', () {
    test('QuestService saves, toggles, and deletes quest packs', () async {
      final svc = QuestService();
      // Allow async loading to finish
      await Future.delayed(const Duration(milliseconds: 20));

      final quest = Quest(
        id: 'q-storage-1',
        title: 'Storage Test Quest',
        description: 'Desc',
        steps: [
          QuestStep(orderIndex: 1, title: 'Step 1', durationType: DurationType.instant),
        ],
      );

      final pack = QuestPack(
        id: 'pack-storage-1',
        title: 'Storage Test Pack',
        quests: [quest],
      );

      await svc.saveQuestPack(pack);
      expect(svc.questPacks.length, 1);
      expect(svc.questPacks.first.id, 'pack-storage-1');
      expect(svc.customQuests.any((q) => q.id == 'q-storage-1'), isTrue);

      // Toggle enabled
      await svc.toggleQuestPackEnabled('pack-storage-1', false);
      expect(svc.questPacks.first.isEnabled, isFalse);

      // Delete pack
      await svc.deleteQuestPack('pack-storage-1');
      expect(svc.questPacks.isEmpty, isTrue);
    });

    test('QuestService exports and imports QuestPack with password encryption', () async {
      final svc = QuestService();
      await Future.delayed(const Duration(milliseconds: 20));

      final quest = Quest(
        id: 'q-enc-1',
        title: 'Secret Quest',
        description: 'Confidential directives',
        steps: [
          QuestStep(orderIndex: 1, title: 'Secret Task', durationType: DurationType.instant, rewardTokens: 50),
        ],
      );

      final pack = QuestPack(
        id: 'pack-enc-1',
        title: 'Classified Protocol Pack',
        quests: [quest],
      );

      final encryptedExport = svc.exportQuestPack(pack, 'SecretPassword123');
      expect(encryptedExport.startsWith('{'), isFalse); // Should be encrypted ciphertext

      // Import with wrong password should fail
      expect(() async => await svc.importQuestPack(encryptedExport, 'WrongPass'), throwsA(anything));

      // Import with correct password
      final importedPack = await svc.importQuestPack(encryptedExport, 'SecretPassword123');
      expect(importedPack.id, 'pack-enc-1');
      expect(importedPack.title, 'Classified Protocol Pack');
      expect(importedPack.quests.first.title, 'Secret Quest');
      expect(svc.questPacks.any((p) => p.id == 'pack-enc-1'), isTrue);
    });

    test('QuestService exports and imports standalone Quest with password encryption', () async {
      final svc = QuestService();
      await Future.delayed(const Duration(milliseconds: 20));

      final quest = Quest(
        id: 'standalone-q',
        title: 'Solo Challenge',
        description: 'Single standalone quest',
        bonusTokensOnComplete: 30,
        steps: [
          QuestStep(orderIndex: 1, title: 'Solo Action', durationType: DurationType.instant, rewardTokens: 10),
        ],
      );

      final encryptedExport = svc.exportQuest(quest, 'KeyPass99');
      expect(encryptedExport.startsWith('{'), isFalse);

      final imported = await svc.importQuestFromJson(encryptedExport, 'KeyPass99');
      expect(imported.id, 'standalone-q');
      expect(imported.title, 'Solo Challenge');
      expect(svc.customQuests.any((q) => q.id == 'standalone-q'), isTrue);
    });
  });
}
