import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/core/security/encryption_helper.dart';

void main() {
  group('EncryptionHelper Tests', () {
    test('Encrypt and decrypt string with passphrase', () {
      const plaintext = 'Sensitive Directive Payload with secret instructions';
      const secret = 'MySecureSecret123';

      final encrypted = EncryptionHelper.encryptString(plaintext, secret);
      expect(encrypted, isNotEmpty);
      expect(encrypted, isNot(equals(plaintext)));

      final decrypted = EncryptionHelper.decryptString(encrypted, secret);
      expect(decrypted, equals(plaintext));
    });

    test('Decryption with wrong password fails or throws', () {
      const plaintext = 'Confidential Order';
      const correctSecret = 'KeyA';
      const wrongSecret = 'KeyB';

      final encrypted = EncryptionHelper.encryptString(plaintext, correctSecret);
      expect(
        () => EncryptionHelper.decryptString(encrypted, wrongSecret),
        throwsA(anything),
      );
    });
  });
}
