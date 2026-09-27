import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/core/security/pairing_crypto.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A code change tells contacts the new code and nothing else.
///
/// It used to send the old and new personal secret to every contact, and each
/// of them replaced the key they shared with this device by it: every contact
/// ended up holding the same key, able to read the others' traffic, and the
/// key they now encrypted with was not the one this device used for them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<(SyncService, PartnerService)> device(
      {String code = 'OLD-1111', String secret = 'personal-old', List<PartnerContact> contacts = const []}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pairing_code', code);
    await prefs.setString('pairing_secret', secret);
    final engine = OrderEngine();
    await engine.init();
    final partners = PartnerService();
    await partners.init();
    for (final c in contacts) {
      await partners.addContact(c);
    }
    final sync = SyncService(engine, partnerService: partners);
    await sync.init(deferNetwork: true);
    sync.debugSentMessages.clear();
    return (sync, partners);
  }

  PartnerContact contact(String id, String code, String secret) => PartnerContact(
        id: id,
        displayName: 'Partner $id',
        pairingCode: code,
        pairingSecret: secret,
      );

  group('Sending a code change', () {
    test('carries no secret of any kind', () async {
      final (sync, _) = await device(contacts: [
        contact('a', 'AAAA-1111', 'shared-with-a'),
        contact('b', 'BBBB-2222', 'shared-with-b'),
      ]);

      await sync.updatePersonalIdentity(newCode: 'NEW-2222', newSecret: 'personal-new');

      final wire = sync.debugSentMessages.map((m) => m.encode()).join('\n');
      expect(sync.debugSentMessages.where((m) => m.type == SyncMessageType.identityMigrated), hasLength(3),
          reason: 'one per contact, and one on the old personal channel');
      for (final secret in ['personal-old', 'personal-new', 'shared-with-a', 'shared-with-b']) {
        expect(wire, isNot(contains(secret)));
      }
      for (final m in sync.debugSentMessages) {
        expect(m.payload.containsKey('oldPairingSecret'), isFalse);
        expect(m.payload.containsKey('newPairingSecret'), isFalse);
      }
    });

    test('each contact\'s copy is proven with the key shared with that contact', () async {
      final (sync, _) = await device(contacts: [contact('a', 'AAAA-1111', 'shared-with-a')]);
      final deviceId = sync.deviceId;

      await sync.updatePersonalIdentity(newCode: 'NEW-2222');

      final toA = sync.debugSentMessages
          .firstWhere((m) => PartnerService.normalizeCode(m.targetCode) == 'AAAA1111');
      expect(toA.payload['proof'],
          SyncService.identityMigrationProof('shared-with-a', deviceId, 'OLD-1111', 'NEW-2222'));
    });

    test('changing only the password tells no one', () async {
      final (sync, _) = await device(contacts: [contact('a', 'AAAA-1111', 'shared-with-a')]);

      await sync.updatePersonalIdentity(newSecret: 'personal-new', newNickname: 'Renamed');

      expect(sync.debugSentMessages, isEmpty);
      expect(sync.pairingSecret, 'personal-new');
    });
  });

  group('Receiving a code change', () {
    const friendId = 'device_friend_99';

    SyncMessage migration({String? proof, Map<String, dynamic> extra = const {}}) => SyncMessage(
          type: SyncMessageType.identityMigrated,
          senderId: friendId,
          payload: {
            'deviceId': friendId,
            'oldPairingCode': 'CODE-AAAA',
            'newPairingCode': 'CODE-BBBB',
            'nickname': 'Master Director Supreme',
            if (proof != null) 'proof': proof,
            ...extra,
          },
        );

    test('follows the new code and keeps the shared key', () async {
      final (sync, partners) = await device(code: 'MINE-0001', contacts: [contact(friendId, 'CODE-AAAA', 'secret_alpha')]);

      await sync.handleIncomingSyncMessage(migration(
          proof: SyncService.identityMigrationProof('secret_alpha', friendId, 'CODE-AAAA', 'CODE-BBBB')));

      final friend = partners.findContactById(friendId)!;
      expect(friend.pairingCode, 'CODE-BBBB');
      expect(friend.pairingSecret, 'secret_alpha');
      expect(friend.displayName, 'Master Director Supreme');
    });

    test('an older build\'s change is followed, but its secret is not taken', () async {
      final (sync, partners) = await device(code: 'MINE-0001', contacts: [contact(friendId, 'CODE-AAAA', 'secret_alpha')]);

      await sync.handleIncomingSyncMessage(migration(extra: {
        'oldPairingSecret': 'their-personal-old',
        'newPairingSecret': 'their-personal-new',
      }));

      final friend = partners.findContactById(friendId)!;
      expect(friend.pairingCode, 'CODE-BBBB');
      expect(friend.pairingSecret, 'secret_alpha');
    });

    test('a change proven with some other key is ignored', () async {
      // Another contact can produce messages this device decrypts, and could
      // otherwise move this friend to a code of their choosing.
      final (sync, partners) = await device(code: 'MINE-0001', contacts: [
        contact(friendId, 'CODE-AAAA', 'secret_alpha'),
        contact('other', 'CODE-ZZZZ', 'secret_other'),
      ]);

      await sync.handleIncomingSyncMessage(migration(
          proof: SyncService.identityMigrationProof('secret_other', friendId, 'CODE-AAAA', 'CODE-BBBB')));

      expect(partners.findContactById(friendId)!.pairingCode, 'CODE-AAAA');
      expect(sync.debugSentMessages, isEmpty);
    });
  });

  test('moving a contact to a new code never touches its key', () async {
    final partners = PartnerService();
    await partners.init();
    await partners.addContact(PartnerContact(
      id: 'dev_user_b',
      displayName: 'Alice',
      pairingCode: 'OLD-1111',
      pairingSecret: 'secOld123',
      verificationCode: '123 456',
    ));

    expect(
        await partners.updateContactPairingIdentity(
            oldCode: 'OLD-1111', newCode: 'NEW-2222', newDisplayName: 'Mistress Alice'),
        isTrue);
    expect(
        await partners.updateContactPairingIdentity(deviceId: 'dev_user_b', newCode: 'NEW-4444'),
        isTrue,
        reason: 'found by device id once the code has moved on');

    final alice = partners.contacts.single;
    expect(alice.pairingCode, 'NEW-4444');
    expect(alice.displayName, 'Mistress Alice');
    expect(alice.pairingSecret, 'secOld123');
    expect(alice.verificationCode, '123 456', reason: 'same key, so the same code still applies');
  });

  test('proofs are bound to both codes and the device', () {
    final base = SyncService.identityMigrationProof('k', 'dev', 'OLD-1', 'NEW-1');
    expect(SyncService.identityMigrationProof('k', 'dev', 'old1', 'new-1'), base,
        reason: 'code formatting does not matter');
    expect(PairingCrypto.proofsMatch(base, SyncService.identityMigrationProof('k', 'dev', 'OLD-1', 'NEW-2')), isFalse);
    expect(PairingCrypto.proofsMatch(base, SyncService.identityMigrationProof('k', 'dev2', 'OLD-1', 'NEW-1')), isFalse);
    expect(PairingCrypto.proofsMatch(base, SyncService.identityMigrationProof('k2', 'dev', 'OLD-1', 'NEW-1')), isFalse);
  });
}
