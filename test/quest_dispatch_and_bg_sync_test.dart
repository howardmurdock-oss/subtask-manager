import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/quest_item.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/services/quest_service.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/chat_service.dart';
import 'package:orders_app/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storage;
  late OrderEngine engine;
  late PartnerService partnerService;
  late ChatService chatService;
  late QuestService questService;
  late SyncService syncService;

  Quest createSampleQuest() {
    return Quest(
      id: 'test-quest-bg-1',
      title: 'Precision Ritual',
      description: 'Chained gauntlet of precision focus.',
      category: 'Ritual',
      bonusTokensOnComplete: 30,
      steps: [
        QuestStep(
          id: 'step-1',
          orderIndex: 1,
          title: 'Kneel in Place',
          description: 'Hold attention kneel.',
          durationType: DurationType.instant,
          rewardTokens: 10,
        ),
        QuestStep(
          id: 'step-2',
          orderIndex: 2,
          title: 'Recite Directives',
          description: 'Recite orders aloud.',
          durationType: DurationType.instant,
          rewardTokens: 15,
        ),
      ],
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = StorageService();
    engine = OrderEngine(storage: storage);
    await engine.init();

    partnerService = PartnerService();
    await partnerService.init();

    chatService = ChatService();
    await chatService.init();

    questService = QuestService();
    syncService = SyncService(engine);
    syncService.attachServices(partnerService, chatService, questService: questService);
  });

  group('Quest Dispatch, Background Ingestion & Delivery Tests', () {
    test('PartnerContact equality works based on id', () {
      final contact1 = PartnerContact(
        id: 'contact-abc',
        displayName: 'Submissive One',
        pairingCode: 'CODE1',
        pairingSecret: 'sec1',
      );
      final contact2 = PartnerContact(
        id: 'contact-abc',
        displayName: 'Submissive Updated Name',
        pairingCode: 'CODE1',
        pairingSecret: 'sec1',
      );
      final contact3 = PartnerContact(
        id: 'contact-different',
        displayName: 'Submissive One',
        pairingCode: 'CODE1',
        pairingSecret: 'sec1',
      );

      expect(contact1 == contact2, isTrue);
      expect(contact1.hashCode, equals(contact2.hashCode));
      expect(contact1 == contact3, isFalse);

      final list = [contact1];
      expect(list.contains(contact2), isTrue);
    });

    test('dispatchQuestToPlayer to PartnerContact.self assigns locally and confirms immediately', () {
      final quest = createSampleQuest();
      final selfContact = PartnerContact.self();

      final result = syncService.dispatchQuestToPlayer(quest, targetPartner: selfContact);
      expect(result, isTrue);

      expect(questService.isUnlocked, isTrue);
      expect(questService.activeQuest, isNotNull);
      expect(questService.activeQuest!.quest.id, equals(quest.id));
      expect(syncService.isQuestConfirmedOnPlayer(quest.id), isTrue);
    });

    test('processPendingBackgroundMessages ingests pending_background_quests_v1', () async {
      final quest = createSampleQuest();
      final prefs = await SharedPreferences.getInstance();

      final payload = {
        'quest': quest.toJson(),
        'senderCode': 'DIR-BG-99',
        'senderName': 'Mistress Raven',
      };

      await prefs.setStringList('pending_background_quests_v1', [jsonEncode(payload)]);

      expect(questService.activeQuest, isNull);
      expect(questService.isUnlocked, isFalse);

      await syncService.processPendingBackgroundMessages();

      expect(questService.isUnlocked, isTrue);
      expect(questService.activeQuest, isNotNull);
      expect(questService.activeQuest!.quest.title, equals('Precision Ritual'));
      expect(questService.activeQuest!.assignedByPartnerName, equals('Mistress Raven'));
      expect(questService.activeQuest!.assignedByPartnerCode, equals('DIR-BG-99'));

      // Verify queue is drained from SharedPreferences
      expect(prefs.getStringList('pending_background_quests_v1'), isNull);
    });

    test('Re-dispatched or replayed quest preserves player current step progress', () async {
      final quest = createSampleQuest();

      // Start quest from director
      questService.assignQuestFromDirector(quest, directorName: 'Director Dan', directorCode: 'DAN123');
      expect(questService.activeQuest!.currentStepIndex, equals(0));

      // Player completes step 1 and advances to step 2
      await questService.completeCurrentStep(engine: engine, sync: syncService);
      expect(questService.activeQuest!.currentStepIndex, equals(1));

      // Director re-sends / network replays the exact same quest
      final replayMsg = SyncMessage(
        type: SyncMessageType.dispatchQuest,
        senderId: 'director-dan-id',
        payload: {
          'quest': quest.toJson(),
          'senderCode': 'DAN123',
          'senderName': 'Director Dan',
        },
      );

      await syncService.handleIncomingSyncMessage(replayMsg);

      // Step progress must NOT be reset to 0!
      expect(questService.activeQuest!.currentStepIndex, equals(1));
      expect(questService.activeQuest!.stepProgress[0].isCompleted, isTrue);
    });

    test('dispatchQuestAck confirms quest delivery on Director', () async {
      final quest = createSampleQuest();

      expect(syncService.isQuestConfirmedOnPlayer(quest.id), isFalse);

      final ackMsg = SyncMessage(
        type: SyncMessageType.dispatchQuestAck,
        senderId: 'sub-dev-id',
        payload: {
          'questId': quest.id,
          'questTitle': quest.title,
          'senderCode': 'SUB456',
        },
      );

      await syncService.handleIncomingSyncMessage(ackMsg);

      expect(syncService.isQuestConfirmedOnPlayer(quest.id), isTrue);
      expect(syncService.isQuestConfirmedOnPlayer('non-existent'), isFalse);
    });
  });
}
