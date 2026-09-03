import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/services/chat_service.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/quest_service.dart';
import 'package:orders_app/services/sync_service.dart';
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

  group('Duplicate Pairing Request Suppression Tests', () {
    test('PartnerService.addIncomingRequest rejects requests from existing contact by pairingCode', () async {
      final existing = PartnerContact(
        id: 'contact_123',
        displayName: 'Existing Director',
        pairingCode: 'DIR-7788',
        pairingSecret: 'secretABC',
        role: PartnerRole.dominant,
      );
      await partnerService.addContact(existing);

      expect(partnerService.contacts.length, 1);
      expect(partnerService.pendingRequests.length, 0);

      // Attempt to add incoming request for same pairing code
      partnerService.addIncomingRequest(IncomingPairingRequest(
        senderId: 'contact_999_different_id',
        senderCode: 'DIR-7788',
        senderName: 'Existing Director',
        senderRole: PartnerRole.dominant,
        sharedSecret: 'secretABC',
        timestamp: DateTime.now(),
      ));

      // Should be ignored
      expect(partnerService.pendingRequests.length, 0);
    });

    test('PartnerService.addIncomingRequest rejects requests from existing contact by senderId', () async {
      final existing = PartnerContact(
        id: 'contact_abc_id',
        displayName: 'Existing Player',
        pairingCode: 'CODE-1111',
        pairingSecret: 'secretXYZ',
        role: PartnerRole.submissive,
      );
      await partnerService.addContact(existing);

      // Attempt to add incoming request with matching senderId
      partnerService.addIncomingRequest(IncomingPairingRequest(
        senderId: 'contact_abc_id',
        senderCode: 'NEW-CODE-2222',
        senderName: 'Existing Player',
        senderRole: PartnerRole.submissive,
        sharedSecret: 'secretXYZ',
        timestamp: DateTime.now(),
      ));

      // Should be ignored
      expect(partnerService.pendingRequests.length, 0);
    });

    test('PartnerService.cleanExistingContactRequests purges pending requests for contacts that exist', () async {
      // Simulate raw pending requests before contacts loaded
      partnerService.addIncomingRequest(IncomingPairingRequest(
        senderId: 'alice_id',
        senderCode: 'ALICE-99',
        senderName: 'Alice',
        senderRole: PartnerRole.dominant,
        sharedSecret: 'secA',
        timestamp: DateTime.now(),
      ));
      expect(partnerService.pendingRequests.length, 1);

      // Add Alice as contact
      final alice = PartnerContact(
        id: 'alice_id',
        displayName: 'Alice Dominant',
        pairingCode: 'ALICE-99',
        pairingSecret: 'secA',
        role: PartnerRole.dominant,
      );
      await partnerService.addContact(alice);

      // Verify pendingRequests was automatically cleared
      expect(partnerService.pendingRequests.length, 0);
    });

    test('SyncService._handleSyncMessage ignores pairingRequest from existing contact and updates secret if changed', () async {
      final friend = PartnerContact(
        id: 'friend_dev_1',
        displayName: 'Best Director',
        pairingCode: 'DIR-1234',
        pairingSecret: 'oldSecret',
        role: PartnerRole.dominant,
      );
      await partnerService.addContact(friend);

      // Incoming pairingRequest with same code but updated secret
      final msg = SyncMessage(
        type: SyncMessageType.pairingRequest,
        senderId: 'friend_dev_1',
        payload: {
          'senderId': 'friend_dev_1',
          'senderCode': 'DIR-1234',
          'senderName': 'Best Director',
          'sharedSecret': 'newSecretUpdated',
          'senderRole': 'dominant',
        },
      );

      await syncService.handleIncomingSyncMessage(msg);

      // No pending request created
      expect(partnerService.pendingRequests.length, 0);

      // Contact was seamlessly updated with new secret
      final updated = partnerService.findContactById('friend_dev_1');
      expect(updated, isNotNull);
      expect(updated!.pairingSecret, 'newSecretUpdated');
    });

    test('SyncService.processPendingBackgroundMessages filters out existing contacts from pending_background_pairings_v1', () async {
      final friend = PartnerContact(
        id: 'sub_55',
        displayName: 'My Player',
        pairingCode: 'SUB-5555',
        pairingSecret: 'secret55',
        role: PartnerRole.submissive,
      );
      await partnerService.addContact(friend);

      final prefs = await SharedPreferences.getInstance();
      final staleBackgroundPairing = {
        'senderId': 'sub_55',
        'senderCode': 'SUB-5555',
        'senderName': 'My Player',
        'sharedSecret': 'secret55',
      };
      await prefs.setStringList('pending_background_pairings_v1', [jsonEncode(staleBackgroundPairing)]);

      // Process pending background messages on app resume
      await syncService.processPendingBackgroundMessages();

      // Ensure no incoming request was queued
      expect(partnerService.pendingRequests.length, 0);
      expect(prefs.getStringList('pending_background_pairings_v1'), isNull);
    });
  });
}
