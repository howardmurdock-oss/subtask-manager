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

    test('PartnerService matches codes regardless of dashes or spaces (GMJ7-UCVY vs GMJ7UCVY)', () async {
      final existing = PartnerContact(
        id: 'contact_dash_test',
        displayName: 'Submissive Player',
        pairingCode: 'GMJ7UCVY', // Saved without dash
        pairingSecret: 'sec123',
        role: PartnerRole.submissive,
      );
      await partnerService.addContact(existing);

      // Attempt to add with dash: GMJ7-UCVY
      partnerService.addIncomingRequest(IncomingPairingRequest(
        senderId: 'random_new_device_id',
        senderCode: 'GMJ7-UCVY', // Received with dash
        senderName: 'Submissive',
        senderRole: PartnerRole.submissive,
        sharedSecret: 'sec123',
        timestamp: DateTime.now(),
      ));

      // Must be rejected as duplicate
      expect(partnerService.pendingRequests.length, 0);
    });

    test('Declining a pairing request persists handled fingerprint and blocks replayed messages', () async {
      final req = IncomingPairingRequest(
        senderId: 'stranger_id',
        senderCode: 'GMJ7-UCVY',
        senderName: 'Submissive',
        senderRole: PartnerRole.submissive,
        sharedSecret: 'randomSecretXYZ',
        timestamp: DateTime.now(),
      );

      partnerService.addIncomingRequest(req);
      expect(partnerService.pendingRequests.length, 1);

      // User declines the request
      await syncService.declinePairingRequest(req);
      expect(partnerService.pendingRequests.length, 0);
      expect(partnerService.isRequestHandled('GMJ7-UCVY', 'randomSecretXYZ'), isTrue);

      // Relay replays the exact same message later
      final replayedMsg = SyncMessage(
        type: SyncMessageType.pairingRequest,
        senderId: 'stranger_id',
        payload: {
          'senderId': 'stranger_id',
          'senderCode': 'GMJ7-UCVY',
          'senderName': 'Submissive',
          'senderRole': 'submissive',
          'sharedSecret': 'randomSecretXYZ',
        },
      );
      await syncService.handleIncomingSyncMessage(replayedMsg);

      // Must still be 0 - not re-added!
      expect(partnerService.pendingRequests.length, 0);
    });

    test('Past personal pairing codes are recognized as self and rejected', () async {
      await syncService.updatePersonalIdentity(newCode: 'PAST-CODE-1');
      await syncService.updatePersonalIdentity(newCode: 'CURRENT-CODE-2');

      final echoMsg = SyncMessage(
        type: SyncMessageType.pairingRequest,
        senderId: 'echo_device',
        payload: {
          'senderId': 'echo_device',
          'senderCode': 'PAST-CODE-1',
          'senderName': 'Submissive',
          'senderRole': 'submissive',
          'sharedSecret': 'secretSelf',
        },
      );

      await syncService.handleIncomingSyncMessage(echoMsg);
      expect(partnerService.pendingRequests.length, 0);
    });
  });
}
