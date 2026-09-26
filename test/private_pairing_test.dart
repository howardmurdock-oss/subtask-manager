import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/core/security/encryption_helper.dart';
import 'package:orders_app/core/security/pairing_crypto.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/sync_service.dart';

/// Pairing used to send the shared secret in the clear, through the Worker,
/// FCM and the public relay. Now each side sends only a public key and works
/// the secret out for itself; these check that nothing secret ever goes out,
/// and that nothing arriving unasked can change a secret.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const aliceCode = 'ALIC-E001';
  const bobCode = 'BOBB-0002';

  Future<(SyncService, PartnerService)> device(String code,
      {List<PartnerContact> contacts = const []}) async {
    // Each device gets its own preferences; the other's state lives on in
    // its services.
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pairing_code', code);
    await prefs.setString('pairing_secret', 'personal-$code');
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

  /// What the relay would carry: the last message [from] sent, as bytes.
  SyncMessage lastSent(SyncService from) =>
      SyncMessage.decode(from.debugSentMessages.last.encode());

  Future<void> deliver(SyncService from, SyncService to) =>
      to.handleIncomingSyncMessage(lastSent(from));

  /// Runs a whole exchange with Alice asking and Bob accepting.
  Future<void> pair(SyncService alice, SyncService bob, PartnerService bobPartners,
      {PartnerContact? repairing}) async {
    if (repairing == null) {
      await alice.sendPairingRequest(targetCode: bobCode, targetName: 'Bob', targetRole: PartnerRole.submissive);
    } else {
      await alice.repairPartner(repairing);
    }
    await deliver(alice, bob);
    // The return value is whether the network send worked, which it never
    // does here; delivery is by hand.
    await bob.acceptPairingRequest(bobPartners.pendingRequests.single);
    await deliver(bob, alice);
    await deliver(alice, bob);
  }

  group('PairingCrypto', () {
    test('both sides derive the same secret and code', () {
      final a = PairingCrypto.generateKeyPair();
      final b = PairingCrypto.generateKeyPair();
      final onA = PairingCrypto.derive(
          privateKey: a.privateKey, requesterKey: a.publicKey, accepterKey: b.publicKey, isRequester: true);
      final onB = PairingCrypto.derive(
          privateKey: b.privateKey, requesterKey: a.publicKey, accepterKey: b.publicKey, isRequester: false);

      expect(onA.secret, onB.secret);
      expect(onA.verificationCode, onB.verificationCode);
      expect(onA.proof, onB.proof);
      expect(onA.verificationCode, matches(RegExp(r'^\d{3} \d{3}$')));
      expect(base64Url.decode('${onA.secret}='), hasLength(32));
    });

    test('a key swapped in transit shows up as different codes', () {
      // Fixed keys, so this does not depend on a one-in-a-million chance.
      final alice = PairingCrypto.keyPairFor(BigInt.from(1111111));
      final bob = PairingCrypto.keyPairFor(BigInt.from(2222222));
      final toAlice = PairingCrypto.keyPairFor(BigInt.from(3333333));
      final toBob = PairingCrypto.keyPairFor(BigInt.from(4444444));

      final aliceSees = PairingCrypto.derive(
          privateKey: alice.privateKey,
          requesterKey: alice.publicKey,
          accepterKey: toAlice.publicKey,
          isRequester: true);
      final bobSees = PairingCrypto.derive(
          privateKey: bob.privateKey,
          requesterKey: toBob.publicKey,
          accepterKey: bob.publicKey,
          isRequester: false);

      expect(aliceSees.secret, isNot(bobSees.secret));
      expect(aliceSees.verificationCode, isNot(bobSees.verificationCode));
    });

    test('public keys that are not points on the curve are refused', () {
      final mine = PairingCrypto.generateKeyPair();
      final good = base64Decode(PairingCrypto.generateKeyPair().publicKey);

      final offCurve = List<int>.from(good)..[64] ^= 0x01;
      final compressed = [0x02, ...good.sublist(1, 33)];
      final truncated = good.sublist(0, 64);

      for (final bad in [offCurve, compressed, truncated]) {
        expect(
          () => PairingCrypto.derive(
              privateKey: mine.privateKey,
              requesterKey: mine.publicKey,
              accepterKey: base64Encode(bad),
              isRequester: true),
          throwsFormatException,
        );
      }
    });
  });

  group('Private pairing', () {
    test('both sides end up with the same secret, and it never went out', () async {
      final (alice, alicePartners) = await device(aliceCode);
      final (bob, bobPartners) = await device(bobCode);

      await alice.sendPairingRequest(targetCode: bobCode, targetName: 'Bob', targetRole: PartnerRole.submissive);
      final request = lastSent(alice);
      expect(request.payload.containsKey('sharedSecret'), isFalse);
      expect(request.payload.containsKey('publicKey'), isFalse,
          reason: 'the key is held back until the accepter has committed to theirs');
      expect(request.payload['commitment'], isNotEmpty);
      expect(alicePartners.isPairingInProgress(bobCode), isTrue);

      await bob.handleIncomingSyncMessage(request);
      final req = bobPartners.pendingRequests.single;
      expect(req.isLegacy, isFalse);
      expect(req.isRepair, isFalse);

      await bob.acceptPairingRequest(req);
      await deliver(bob, alice);
      await deliver(alice, bob);

      final bobOnAlice = alicePartners.findContactByCode(bobCode)!;
      final aliceOnBob = bobPartners.findContactByCode(aliceCode)!;
      expect(bobOnAlice.pairingSecret, aliceOnBob.pairingSecret);
      expect(bobOnAlice.verificationCode, isNotNull);
      expect(bobOnAlice.verificationCode, aliceOnBob.verificationCode);
      expect(alicePartners.isPairingInProgress(bobCode), isFalse);
      expect(bobPartners.isPairingInProgress(aliceCode), isFalse);

      // Everything either side put on the wire, as the relays saw it.
      final wire = [...alice.debugSentMessages, ...bob.debugSentMessages]
          .map((m) => m.encode())
          .join('\n');
      expect(wire, isNot(contains(bobOnAlice.pairingSecret)));
      expect(wire, isNot(contains(bobOnAlice.verificationCode)));

      // And the agreed secret is one they can actually talk with.
      final sealed = EncryptionHelper.encryptString('hello', bobOnAlice.pairingSecret);
      expect(EncryptionHelper.decryptString(sealed, aliceOnBob.pairingSecret), 'hello');
    });

    test('the key revealed at the end must match the commitment', () async {
      final (alice, _) = await device(aliceCode);
      final (bob, bobPartners) = await device(bobCode);

      await alice.sendPairingRequest(targetCode: bobCode, targetRole: PartnerRole.submissive);
      await deliver(alice, bob);
      await bob.acceptPairingRequest(bobPartners.pendingRequests.single);
      await deliver(bob, alice);

      // Swap the revealed key for another; the commitment no longer fits.
      final confirm = lastSent(alice);
      final forged = SyncMessage.fromJson({
        ...confirm.toJson(),
        'payload': {...confirm.payload, 'publicKey': PairingCrypto.generateKeyPair().publicKey},
      });
      final before = bobPartners.findContactByCode(aliceCode)!.pairingSecret;
      await bob.handleIncomingSyncMessage(forged);

      expect(bobPartners.findContactByCode(aliceCode)!.pairingSecret, before);
      expect(bobPartners.findContactByCode(aliceCode)!.verificationCode, isNull);
      expect(bobPartners.isPairingInProgress(aliceCode), isTrue);
    });

    test('an accept for an exchange this device never started changes nothing', () async {
      final bobContact = PartnerContact(
          displayName: 'Bob', pairingCode: bobCode, pairingSecret: 'current', role: PartnerRole.submissive);
      final (alice, alicePartners) = await device(aliceCode, contacts: [bobContact]);

      await alice.handleIncomingSyncMessage(SyncMessage(
        type: SyncMessageType.pairingAccept,
        senderId: 'someone',
        payload: {
          'senderCode': bobCode,
          'pairing': PairingCrypto.version,
          'commitment': PairingCrypto.commitmentFor(PairingCrypto.generateKeyPair().publicKey),
          'publicKey': PairingCrypto.generateKeyPair().publicKey,
        },
      ));

      expect(alicePartners.findContactByCode(bobCode)!.pairingSecret, 'current');
      expect(alice.debugSentMessages, isEmpty);
    });

    test('an older build\'s accept cannot overwrite a secret', () async {
      // It used to replace the stored secret with whatever it carried, so
      // anyone who knew a code could redirect a pairing to themselves.
      final bobContact = PartnerContact(
          displayName: 'Bob', pairingCode: bobCode, pairingSecret: 'current', role: PartnerRole.submissive);
      final (alice, alicePartners) = await device(aliceCode, contacts: [bobContact]);

      await alice.handleIncomingSyncMessage(SyncMessage(
        type: SyncMessageType.pairingAccept,
        senderId: 'someone',
        payload: {'senderCode': bobCode, 'senderName': 'Bob', 'sharedSecret': 'attacker-chosen'},
      ));

      expect(alicePartners.findContactByCode(bobCode)!.pairingSecret, 'current');
    });

    test('an older build\'s request is shown but cannot be accepted', () async {
      final (bob, bobPartners) = await device(bobCode);

      await bob.handleIncomingSyncMessage(SyncMessage(
        type: SyncMessageType.pairingRequest,
        senderId: 'old_device',
        payload: {
          'senderId': 'old_device',
          'senderCode': aliceCode,
          'senderName': 'Alice',
          'senderRole': 'dominant',
          'sharedSecret': 'sent-in-the-clear',
        },
      ));

      final req = bobPartners.pendingRequests.single;
      expect(req.isLegacy, isTrue);
      expect(await bob.acceptPairingRequest(req), isFalse);
      expect(bobPartners.findContactByCode(aliceCode), isNull);
      expect(bob.debugSentMessages, isEmpty);
    });

    test('re-pairing replaces the secret only once both sides agree', () async {
      final (alice, alicePartners) = await device(aliceCode);
      final (bob, bobPartners) = await device(bobCode);
      await pair(alice, bob, bobPartners);
      final firstSecret = alicePartners.findContactByCode(bobCode)!.pairingSecret;

      await alice.repairPartner(alicePartners.findContactByCode(bobCode)!);
      await deliver(alice, bob);
      final req = bobPartners.pendingRequests.single;
      expect(req.isRepair, isTrue, reason: 'Alice is already a contact');

      // Until Bob accepts, both keep talking with the old secret.
      expect(alicePartners.findContactByCode(bobCode)!.pairingSecret, firstSecret);
      await bob.acceptPairingRequest(req);
      expect(bobPartners.findContactByCode(aliceCode)!.pairingSecret, firstSecret);

      await deliver(bob, alice);
      await deliver(alice, bob);

      final onAlice = alicePartners.findContactByCode(bobCode)!;
      final onBob = bobPartners.findContactByCode(aliceCode)!;
      expect(onAlice.pairingSecret, isNot(firstSecret));
      expect(onAlice.pairingSecret, onBob.pairingSecret);
      expect(onAlice.verificationCode, onBob.verificationCode);
    });

    test('a request queued by the background isolate is still a private one', () async {
      final (bob, bobPartners) = await device(bobCode);
      final commitment = PairingCrypto.commitmentFor(PairingCrypto.generateKeyPair().publicKey);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('pending_background_pairings_v1', [
        jsonEncode({
          'senderId': 'alice_device',
          'senderCode': aliceCode,
          'senderName': 'Alice',
          'senderRole': 'dominant',
          'pairing': PairingCrypto.version,
          'commitment': commitment,
        }),
      ]);
      await bob.processPendingBackgroundMessages();

      final req = bobPartners.pendingRequests.single;
      expect(req.exchangeId, commitment);
      expect(req.senderRole, PartnerRole.dominant);
      expect(req.isLegacy, isFalse);
    });

    test('a half-finished exchange survives a restart', () async {
      final (alice, _) = await device(aliceCode);
      await alice.sendPairingRequest(targetCode: bobCode, targetRole: PartnerRole.submissive);

      final reloaded = PartnerService();
      await reloaded.init();
      expect(reloaded.isPairingInProgress(bobCode), isTrue);
    });
  });

  test('changing a secret by hand drops the verification code', () {
    final paired = PartnerContact(
      displayName: 'Bob',
      pairingCode: bobCode,
      pairingSecret: 'agreed',
      verificationCode: '123 456',
    );
    expect(paired.copyWith(displayName: 'Robert').verificationCode, '123 456');
    expect(paired.copyWith(pairingSecret: 'typed-in').verificationCode, isNull);
    expect(PartnerContact.fromJson(paired.toJson()).verificationCode, '123 456');
  });
}
