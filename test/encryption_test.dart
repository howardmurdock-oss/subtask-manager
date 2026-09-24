import 'dart:convert';
import 'dart:math';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/core/security/encryption_helper.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Produced by the v1.4.12 helper (AES-CBC, no version field) and frozen here,
// so these keep proving that what older builds sent or exported still opens.
const _legacySyncSecret = 'K7QX-M2PA-9RTW';
const _legacySync =
    'eyJpdiI6IjdCWVhCZnNFcmEvT01KcXl1ZVB3bmc9PSIsImRhdGEiOiJwWm55OVQzd3Z4UWhkRnZId2dPWFQwZjh0bGNPV29HTW5GZTkxcmtQeU5jaUtRL25ad0tYNTBCVUR3K3VZRzFkYjVlaU5EcWkwL2JwSEV3bk1OY0dWdlVGT21pKzZDR29lemROY0NEVDloQ0FYWkxEekZsdnVIZzl6RUpzUWo2dHRvNkJpZjBuWG1SRnlQVTNHQThsZEZiMVhzcmNLUDRlWGsrb1pXaUJKUTEzbVBYOGVrbkp1RGczQ201aGdJaHNpOXBodCsxeU9XSDIxQUFGb3JJdUV4dHRGSWJOdVJvRXZNeWh4eVQ0MVh3PSJ9';
const _legacyPackPassword = 'my pack password';
const _legacyPack =
    'eyJpdiI6Ik52enk0TDlTeXVacm1VN1BNUFRWd0E9PSIsImRhdGEiOiIyazlGY3JxbkhzaU5VVzY2WkV3cFZEKzhjdWg5ajlKbXFJM1A4K3ZLb3R0UjUrQUo4MkMwQm94NFErUDUrd3czYzY1ZjA3b3pFSU9VUVZXUDdRemxnRlRZQTlRUEFwaThpR2xMcS82RDg3VkJTQXZMNGgrbmp3c1JPaTQ5RjRsUSJ9';
// 'Confidential Order' under 'KeyA'.
const _legacyKeyA =
    'eyJpdiI6ImMxL3l1S2FlcmorU1BXWTcySnRCT3c9PSIsImRhdGEiOiJzcG5TUkdIelBKemRvUkowbWtGKzJ4eVFXbVlpdDlMa3dPVlJlODZKRDhzPSJ9';

/// The decrypt path of builds up to v1.4.12, verbatim, standing in for a
/// device that has not updated.
String _preV2Decrypt(String encryptedBase64, String passphrase) {
  final key = EncryptionHelper.deriveKey(passphrase);
  final map = jsonDecode(utf8.decode(base64Decode(encryptedBase64)))
      as Map<String, dynamic>;
  final iv = enc.IV.fromBase64(map['iv'] as String);
  final cipher = enc.Encrypted.fromBase64(map['data'] as String);
  return enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc))
      .decrypt(cipher, iv: iv);
}

Map<String, dynamic> _envelope(String payload) =>
    jsonDecode(utf8.decode(base64Decode(payload))) as Map<String, dynamic>;

String _seal(Map<String, dynamic> envelope) =>
    base64Encode(utf8.encode(jsonEncode(envelope)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EncryptionHelper Tests', () {
    test('Encrypt and decrypt string with passphrase', () {
      const plaintext = 'Sensitive Directive Payload with secret instructions';
      const secret = 'MySecureSecret123';

      for (final version in [1, 2]) {
        final encrypted =
            EncryptionHelper.encryptString(plaintext, secret, version: version);
        expect(encrypted, isNotEmpty);
        expect(encrypted, isNot(equals(plaintext)));

        final decrypted = EncryptionHelper.decryptString(encrypted, secret);
        expect(decrypted, equals(plaintext), reason: 'v$version');
      }
    });

    test('Decryption with wrong password fails or throws', () {
      // v2 is authenticated: a wrong key fails the tag check, so this throws
      // on every run rather than on about 255 runs in 256.
      final encrypted = EncryptionHelper.encryptString(
          'Confidential Order', 'KeyA',
          version: 2);
      expect(
        () => EncryptionHelper.decryptString(encrypted, 'KeyB'),
        throwsA(anything),
      );

      // v1 is not, so the legacy half uses a fixed payload rather than a
      // fresh random one.
      expect(
        () => EncryptionHelper.decryptString(_legacyKeyA, 'KeyB'),
        throwsA(anything),
      );
      expect(EncryptionHelper.decryptString(_legacyKeyA, 'KeyA'),
          'Confidential Order');
    });

    test('A wrong key never decrypts a v2 payload', () {
      // Callers try several secrets in turn and take the first that does not
      // throw, so a wrong key must throw every time, not usually.
      final rng = Random(42);
      for (var i = 0; i < 1000; i++) {
        final plain = 'x' * rng.nextInt(40);
        final encrypted =
            EncryptionHelper.encryptString(plain, 'right-$i', version: 2);
        expect(() => EncryptionHelper.decryptString(encrypted, 'wrong-$i'),
            throwsA(anything),
            reason: 'iteration $i');
      }
    });

    test('Flipping any bit of a v2 payload is rejected', () {
      final msg = SyncMessage(
        type: SyncMessageType.adjustTokens,
        senderId: 'dev-a',
        payload: {'delta': 5},
      ).encode();
      final env = _envelope(
          EncryptionHelper.encryptString(msg, 'secret', version: 2));

      for (final field in ['n', 'ct']) {
        final original = base64Decode(env[field] as String);
        for (var bit = 0; bit < original.length * 8; bit++) {
          final bytes = List<int>.from(original);
          bytes[bit ~/ 8] ^= 1 << (bit % 8);
          final tampered = _seal({...env, field: base64Encode(bytes)});
          expect(() => EncryptionHelper.decryptString(tampered, 'secret'),
              throwsA(anything),
              reason: '$field bit $bit');
        }
      }
    });

    test('Truncated or stripped v2 payloads are rejected', () {
      final env = _envelope(
          EncryptionHelper.encryptString('{"a":1}', 'secret', version: 2));
      final ct = base64Decode(env['ct'] as String);

      // Tag cut short.
      final truncated = _seal(
          {...env, 'ct': base64Encode(ct.sublist(0, ct.length - 1))});
      expect(() => EncryptionHelper.decryptString(truncated, 'secret'),
          throwsA(anything));

      // Version removed, to push it down the unauthenticated path.
      final downgraded = _seal(Map.of(env)..remove('v'));
      expect(() => EncryptionHelper.decryptString(downgraded, 'secret'),
          throwsA(anything));

      // A version this build does not know.
      final future = _seal({...env, 'v': 3});
      expect(() => EncryptionHelper.decryptString(future, 'secret'),
          throwsA(isA<FormatException>()));
    });

    test('Legacy sync payloads still decrypt', () {
      final plain =
          EncryptionHelper.decryptString(_legacySync, _legacySyncSecret);
      final msg = SyncMessage.decode(plain);
      expect(msg.id, 'fixture-1');
      expect(msg.type, SyncMessageType.chatMessage);
      expect(msg.payload['text'], 'legacy hello');
    });

    test('Packs exported by older versions still import', () async {
      SharedPreferences.setMockInitialValues({});
      final engine = OrderEngine();
      await engine.init();

      final pack =
          engine.importOrderPackFromJson(_legacyPack, _legacyPackPassword);
      expect(pack.id, 'pack-legacy');
      expect(pack.title, 'Legacy Pack');
      expect(engine.isOrderPackInstalled('pack-legacy'), isTrue);

      expect(() => engine.importOrderPackFromJson(_legacyPack, 'not it'),
          throwsA(anything));
    });

    test('Default output is still readable by builds that predate v2', () {
      // Until the whole fleet reads v2, what this build sends must open on a
      // device that has not updated. Raising writeVersion is meant to fail
      // this test: update it in the same change, deliberately.
      expect(EncryptionHelper.writeVersion, 1);
      final payload = EncryptionHelper.encryptString('hello', 'secret');
      expect(_envelope(payload).containsKey('v'), isFalse);
      expect(_preV2Decrypt(payload, 'secret'), 'hello');
    });

    test('A build that predates v2 rejects a v2 payload outright', () {
      // It has no `iv` field to read, so an old device fails before running
      // CBC over GCM bytes rather than handing garbage to its caller.
      final payload =
          EncryptionHelper.encryptString('hello', 'secret', version: 2);
      expect(() => _preV2Decrypt(payload, 'secret'), throwsA(anything));
    });
  });
}
