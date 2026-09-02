import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/chat_message.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/order_pack.dart';
import 'package:orders_app/models/reward_item.dart';
import 'package:orders_app/models/reward_pack.dart';
import 'package:orders_app/models/quest_item.dart';
import 'package:orders_app/models/quest_pack.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/services/chat_service.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/quest_service.dart';
import 'package:orders_app/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Chat Pack Transfer Model & Service Tests', () {
    test('ChatMessage correctly serializes and restores pack transfer metadata', () {
      final msg = ChatMessage(
        partnerId: 'partner-1',
        senderId: 'dev-1',
        senderName: 'Director',
        text: 'Here is your new order pack',
        packType: 'orderPack',
        packTitle: 'Intense Discipline',
        packItemCount: 5,
        packData: jsonEncode({'id': 'pack-123', 'title': 'Intense Discipline', 'orders': []}),
        isEncryptedPack: false,
      );

      expect(msg.isPackTransfer, isTrue);

      final json = msg.toJson();
      final restored = ChatMessage.fromJson(json);

      expect(restored.isPackTransfer, isTrue);
      expect(restored.packType, 'orderPack');
      expect(restored.packTitle, 'Intense Discipline');
      expect(restored.packItemCount, 5);
      expect(restored.packData, contains('pack-123'));
    });

    test('OrderEngine imports OrderPack from chat message payload and tracks installed state', () async {
      final storage = StorageService();
      final engine = OrderEngine(storage: storage);

      final order1 = OrderItem(
        id: 'chat-ord-1',
        title: 'Wall Sit Drill',
        description: 'Hold for 60 seconds',
        category: 'Physical',
        tier: 2,
        actionDurationSeconds: 60,
        rewardTokens: 10,
        penaltyTokens: 5,
      );

      final pack = OrderPack(
        id: 'chat-pack-1',
        title: 'Endurance Builder',
        description: 'Transferred via chat',
        author: 'Director Alpha',
        orders: [order1],
      );

      expect(engine.isOrderPackInstalled('chat-pack-1', title: 'Endurance Builder'), isFalse);

      final rawJson = jsonEncode(pack.toJson());
      final imported = engine.importOrderPackFromJson(rawJson);

      expect(imported.id, 'chat-pack-1');
      expect(imported.title, 'Endurance Builder');
      expect(engine.isOrderPackInstalled('chat-pack-1', title: 'Endurance Builder'), isTrue);
      expect(engine.packs.any((p) => p.id == 'chat-pack-1'), isTrue);
    });

    test('OrderEngine imports RewardPack from chat message payload and tracks installed state', () async {
      final storage = StorageService();
      final engine = OrderEngine(storage: storage);

      final reward1 = RewardItem(
        id: 'chat-rew-1',
        title: 'Movie Night Privilege',
        description: 'Choose evening film',
        cost: 25,
        category: 'Privilege',
      );

      final pack = RewardPack(
        id: 'chat-rewpack-1',
        title: 'Weekend Privileges',
        description: 'Shared in chat',
        author: 'Director Alpha',
        rewards: [reward1],
      );

      expect(engine.isRewardPackInstalled('chat-rewpack-1', title: 'Weekend Privileges'), isFalse);

      final rawJson = jsonEncode(pack.toJson());
      final imported = engine.importRewardPackFromJson(rawJson);

      expect(imported.id, 'chat-rewpack-1');
      expect(imported.title, 'Weekend Privileges');
      expect(engine.isRewardPackInstalled('chat-rewpack-1', title: 'Weekend Privileges'), isTrue);
      expect(engine.rewardPacks.any((p) => p.id == 'chat-rewpack-1'), isTrue);
    });

    test('QuestService imports QuestPack and Quest from chat message payloads', () async {
      final questSvc = QuestService();
      await Future.delayed(const Duration(milliseconds: 20));

      final step = QuestStep(
        orderIndex: 1,
        title: 'Chat Induction Step',
        durationType: DurationType.instant,
        rewardTokens: 15,
      );

      final quest = Quest(
        id: 'chat-q-1',
        title: 'Chat Transfer Quest',
        description: 'Received in messenger',
        steps: [step],
      );

      final questPack = QuestPack(
        id: 'chat-qp-1',
        title: 'Messenger Bundle',
        description: 'Transferred over messenger',
        quests: [quest],
      );

      // Import Quest Pack
      final packJson = jsonEncode(questPack.toJson());
      final importedPack = await questSvc.importQuestPack(packJson);

      expect(importedPack.id, 'chat-qp-1');
      expect(importedPack.title, 'Messenger Bundle');
      expect(questSvc.questPacks.any((p) => p.id == 'chat-qp-1'), isTrue);

      // Import standalone Quest
      final singleQuest = Quest(
        id: 'chat-q-solo',
        title: 'Solo Shared Quest',
        description: 'Transferred individually',
        steps: [step],
      );
      final singleJson = jsonEncode(singleQuest.toJson());
      final importedQuest = await questSvc.importQuestFromJson(singleJson);

      expect(importedQuest.id, 'chat-q-solo');
      expect(importedQuest.title, 'Solo Shared Quest');
      expect(questSvc.customQuests.any((q) => q.id == 'chat-q-solo'), isTrue);
    });

    test('ChatService stores and retrieves pack transfer messages in order', () async {
      final chatService = ChatService();
      await chatService.init();

      final packMsg = ChatMessage(
        id: 'msg-pack-1',
        partnerId: 'partner-test-1',
        senderId: 'dev-1',
        senderName: 'Director',
        text: 'Shared Order Pack: "Core Discipline" (10 directives)',
        packType: 'orderPack',
        packTitle: 'Core Discipline',
        packItemCount: 10,
        packData: jsonEncode({'id': 'core-1', 'title': 'Core Discipline', 'orders': []}),
        isOutgoing: true,
      );

      await chatService.addMessage(packMsg);

      final history = chatService.getMessages('partner-test-1');
      expect(history.length, 1);
      expect(history.first.id, 'msg-pack-1');
      expect(history.first.isPackTransfer, isTrue);
      expect(history.first.packType, 'orderPack');
      expect(history.first.packTitle, 'Core Discipline');
      expect(history.first.packItemCount, 10);
    });
  });
}
