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

  Quest createSampleQuest() {
    return Quest(
      id: 'test-cross-quest-1',
      title: 'Discipline Trial Alpha',
      description: 'Chained gauntlet of physical and posture control.',
      category: 'Trial',
      bonusTokensOnComplete: 50,
      steps: [
        QuestStep(
          id: 'step-1',
          orderIndex: 1,
          title: 'Deep Breathing Stance',
          description: 'Stand tall with erect spine for 60 seconds.',
          durationType: DurationType.actionTimer,
          actionDurationSeconds: 60,
          rewardTokens: 10,
        ),
        QuestStep(
          id: 'step-2',
          orderIndex: 2,
          title: 'Attention Kneel',
          description: 'Remain still with perfect posture.',
          durationType: DurationType.instant,
          rewardTokens: 15,
        ),
      ],
    );
  }

  group('Quest Cross-Device Deployment & Synchronization Tests', () {
    test('dispatchQuestToPlayer records quest in Director remotePlayerQuests', () {
      final quest = createSampleQuest();
      final partner = PartnerContact(
        id: 'sub-partner-1',
        displayName: 'Test Submissive',
        pairingCode: 'SUB123',
        pairingSecret: 'secret123',
        role: PartnerRole.submissive,
      );

      final dispatched = syncService.dispatchQuestToPlayer(quest, targetPartner: partner);
      expect(dispatched, isTrue);

      final remoteQuest = questService.remotePlayerQuests['sub-partner-1'];
      expect(remoteQuest, isNotNull);
      expect(remoteQuest!.quest.title, equals('Discipline Trial Alpha'));
      expect(remoteQuest.assignedByPartnerName, equals('Test Submissive'));
    });

    test('Incoming dispatchQuest message activates quest and auto-unlocks player access', () async {
      expect(questService.isUnlocked, isFalse);
      expect(questService.activeQuest, isNull);

      final sampleQuest = createSampleQuest();
      final msg = SyncMessage(
        type: SyncMessageType.dispatchQuest,
        senderId: 'remote-director-id',
        payload: {
          'quest': sampleQuest.toJson(),
          'senderCode': 'DIR-CODE',
          'senderName': 'Sir Director',
        },
      );

      await syncService.handleIncomingSyncMessage(msg);

      expect(questService.isUnlocked, isTrue);
      expect(questService.activeQuest, isNotNull);
      expect(questService.activeQuest!.quest.title, equals('Discipline Trial Alpha'));
      expect(questService.activeQuest!.assignedByPartnerName, equals('Sir Director'));
      expect(questService.activeQuest!.currentStepIndex, equals(0));
    });

    test('Incoming sendState payload with activeQuest updates Director tracking', () async {
      final sampleQuest = createSampleQuest();
      final activeQuest = ActiveQuest(
        quest: sampleQuest,
        currentStepIndex: 1,
        assignedByPartnerName: 'Sir Director',
        assignedByPartnerCode: 'DIR-CODE',
      );

      final stateMsg = SyncMessage(
        type: SyncMessageType.sendState,
        senderId: 'sub-device-1',
        payload: {
          'tokens': 120,
          'streak': 5,
          'score': 85,
          'activeOrders': [],
          'underReviewOrders': [],
          'pendingRedemptions': [],
          'activeQuest': activeQuest.toJson(),
        },
      );

      await syncService.handleIncomingSyncMessage(stateMsg);

      final tracked = questService.remotePlayerQuests['sub-device-1'];
      expect(tracked, isNotNull);
      expect(tracked!.quest.title, equals('Discipline Trial Alpha'));
      expect(tracked.currentStepIndex, equals(1));
    });

    test('Incoming questStepCompleted updates remote quest step index and notifies Director', () async {
      final sampleQuest = createSampleQuest();
      questService.recordDispatchedQuest('sub-device-1', sampleQuest);

      final stepCompletedMsg = SyncMessage(
        type: SyncMessageType.questStepCompleted,
        senderId: 'sub-device-1',
        payload: {
          'questId': sampleQuest.id,
          'questTitle': sampleQuest.title,
          'stepIndex': 1,
          'stepTitle': 'Attention Kneel',
          'totalSteps': 2,
          'tokensAwarded': 10,
          'senderName': 'Submissive',
        },
      );

      await syncService.handleIncomingSyncMessage(stepCompletedMsg);

      final tracked = questService.remotePlayerQuests['sub-device-1'];
      expect(tracked, isNotNull);
      expect(tracked!.currentStepIndex, equals(1));
      expect(tracked.stepProgress[1].isCompleted, isTrue);
    });

    test('Incoming questCompleted marks remote quest conquered on Director', () async {
      final sampleQuest = createSampleQuest();
      questService.recordDispatchedQuest('sub-device-1', sampleQuest);

      final questCompletedMsg = SyncMessage(
        type: SyncMessageType.questCompleted,
        senderId: 'sub-device-1',
        payload: {
          'questId': sampleQuest.id,
          'questTitle': sampleQuest.title,
          'totalSteps': 2,
          'bonusTokens': 50,
          'senderName': 'Submissive',
        },
      );

      await syncService.handleIncomingSyncMessage(questCompletedMsg);

      final tracked = questService.remotePlayerQuests['sub-device-1'];
      expect(tracked, isNotNull);
      expect(tracked!.isCompleted, isTrue);
      expect(tracked.completedAt, isNotNull);
    });
  });
}
