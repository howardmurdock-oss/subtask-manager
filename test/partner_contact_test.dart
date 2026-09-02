import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/services/partner_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PartnerContact Model & PartnerService Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('PartnerContact serialization and deserialization round-trip', () {
      final contact = PartnerContact(
        id: 'partner_1',
        displayName: 'Submissive Alice',
        pairingCode: 'ABC123',
        pairingSecret: 'pass456',
        role: PartnerRole.submissive,
        isBlocked: false,
        unreadCount: 3,
      );

      final json = contact.toJson();
      final recovered = PartnerContact.fromJson(json);

      expect(recovered.id, 'partner_1');
      expect(recovered.displayName, 'Submissive Alice');
      expect(recovered.pairingCode, 'ABC123');
      expect(recovered.pairingSecret, 'pass456');
      expect(recovered.role, PartnerRole.submissive);
      expect(recovered.isBlocked, false);
      expect(recovered.unreadCount, 3);
    });

    test('PartnerService can add, update, block, and delete partners', () async {
      final service = PartnerService();
      await service.init();

      expect(service.contacts.length, 0);

      final p1 = PartnerContact(
        id: 'p1',
        displayName: 'Submissive One',
        pairingCode: 'SUB001',
        pairingSecret: 'secret1',
      );
      final p2 = PartnerContact(
        id: 'p2',
        displayName: 'Dominant Master',
        pairingCode: 'DOM002',
        pairingSecret: 'secret2',
        role: PartnerRole.dominant,
      );

      await service.addContact(p1);
      await service.addContact(p2);

      expect(service.contacts.length, 2);
      expect(service.activePartnerId, 'p1');

      // Test blocking
      expect(service.isSenderBlocked('p1'), false);
      await service.setBlocked('p1', true);
      expect(service.isSenderBlocked('p1'), true);
      expect(service.isSenderBlocked('SUB001'), true);
      expect(service.unblockedContacts.length, 1);
      expect(service.blockedContacts.length, 1);

      // Test unblocking
      await service.toggleBlock('p1');
      expect(service.isSenderBlocked('p1'), false);
      expect(service.unblockedContacts.length, 2);

      // Test active partner switch
      await service.setActivePartner('p2');
      expect(service.activePartnerId, 'p2');
      expect(service.activePartner?.displayName, 'Dominant Master');

      // Test delete
      await service.deleteContact('p1');
      expect(service.contacts.length, 1);
      expect(service.findContactById('p1'), isNull);
    });

    test('Unread message count increments and resets accurately', () async {
      final service = PartnerService();
      await service.init();

      final p = PartnerContact(
        id: 'p_test',
        displayName: 'Test Partner',
        pairingCode: 'TST111',
        pairingSecret: 'sec',
      );
      await service.addContact(p);

      expect(service.totalUnreadCount, 0);

      await service.incrementUnread('p_test');
      await service.incrementUnread('p_test');
      expect(service.totalUnreadCount, 2);
      expect(service.findContactById('p_test')?.unreadCount, 2);

      await service.resetUnread('p_test');
      expect(service.totalUnreadCount, 0);
      expect(service.findContactById('p_test')?.unreadCount, 0);
    });

    test('IncomingPairingRequest management in PartnerService', () async {
      final service = PartnerService();
      await service.init();

      expect(service.pendingRequests.length, 0);

      final req = IncomingPairingRequest(
        senderId: 'dev_999',
        senderCode: 'REQ888',
        senderName: 'Master Alex',
        senderRole: PartnerRole.dominant,
        sharedSecret: 'supersecret',
        timestamp: DateTime.now(),
      );

      service.addIncomingRequest(req);
      expect(service.pendingRequests.length, 1);
      expect(service.pendingRequests.first.senderName, 'Master Alex');

      service.removeIncomingRequest('dev_999');
      expect(service.pendingRequests.length, 0);
    });
  });
}
