import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Identity Migration Protocol Tests', () {
    test('SyncMessageType.identityMigrated encodes and decodes properly', () {
      final msg = SyncMessage(
        type: SyncMessageType.identityMigrated,
        senderId: 'dev_user_b',
        payload: {
          'deviceId': 'dev_user_b',
          'oldPairingCode': 'OLD-1111',
          'newPairingCode': 'NEW-2222',
          'oldPairingSecret': 'secOld123',
          'newPairingSecret': 'secNew456',
          'nickname': 'Mistress Alice',
        },
      );

      final encoded = msg.encode();
      final decoded = SyncMessage.decode(encoded);

      expect(decoded.type, SyncMessageType.identityMigrated);
      expect(decoded.payload['oldPairingCode'], 'OLD-1111');
      expect(decoded.payload['newPairingCode'], 'NEW-2222');
      expect(decoded.payload['newPairingSecret'], 'secNew456');
      expect(decoded.payload['nickname'], 'Mistress Alice');
    });

    test('PartnerService.updateContactPairingIdentity updates contact by oldCode', () async {
      final partnerSvc = PartnerService();
      await partnerSvc.init();

      final contact = PartnerContact(
        id: 'dev_user_b',
        displayName: 'Alice',
        pairingCode: 'OLD-1111',
        pairingSecret: 'secOld123',
      );
      await partnerSvc.addContact(contact);

      expect(partnerSvc.contacts.length, 1);
      expect(partnerSvc.contacts.first.pairingCode, 'OLD-1111');

      final updated = await partnerSvc.updateContactPairingIdentity(
        oldCode: 'OLD-1111',
        newCode: 'NEW-2222',
        newSecret: 'secNew456',
        newDisplayName: 'Mistress Alice',
      );

      expect(updated, isTrue);
      expect(partnerSvc.contacts.first.pairingCode, 'NEW-2222');
      expect(partnerSvc.contacts.first.pairingSecret, 'secNew456');
      expect(partnerSvc.contacts.first.displayName, 'Mistress Alice');
    });

    test('PartnerService.updateContactPairingIdentity updates contact by deviceId fallback', () async {
      final partnerSvc = PartnerService();
      await partnerSvc.init();

      final contact = PartnerContact(
        id: 'dev_user_b',
        displayName: 'Bob',
        pairingCode: 'OLD-3333',
        pairingSecret: 'secOld789',
      );
      await partnerSvc.addContact(contact);

      final updated = await partnerSvc.updateContactPairingIdentity(
        deviceId: 'dev_user_b',
        newCode: 'NEW-4444',
        newSecret: 'secNew999',
      );

      expect(updated, isTrue);
      expect(partnerSvc.contacts.first.pairingCode, 'NEW-4444');
      expect(partnerSvc.contacts.first.pairingSecret, 'secNew999');
    });

    test('SyncService handles incoming identityMigrated message and updates contact automatically', () async {
      final engine = OrderEngine();
      final partnerSvc = PartnerService();
      await partnerSvc.init();

      final friend = PartnerContact(
        id: 'device_friend_99',
        displayName: 'Master Director',
        pairingCode: 'CODE-AAAA',
        pairingSecret: 'secret_alpha',
      );
      await partnerSvc.addContact(friend);

      final sync = SyncService(engine, partnerService: partnerSvc);

      final migrationMsg = SyncMessage(
        type: SyncMessageType.identityMigrated,
        senderId: 'device_friend_99',
        payload: {
          'deviceId': 'device_friend_99',
          'oldPairingCode': 'CODE-AAAA',
          'newPairingCode': 'CODE-BBBB',
          'oldPairingSecret': 'secret_alpha',
          'newPairingSecret': 'secret_beta',
          'nickname': 'Master Director Supreme',
        },
      );

      await sync.handleIncomingSyncMessage(migrationMsg);

      final updatedFriend = partnerSvc.findContactById('device_friend_99');
      expect(updatedFriend, isNotNull);
      expect(updatedFriend!.pairingCode, 'CODE-BBBB');
      expect(updatedFriend.pairingSecret, 'secret_beta');
      expect(updatedFriend.displayName, 'Master Director Supreme');
    });
  });
}
