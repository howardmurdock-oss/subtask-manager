import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;

class EncryptionHelper {
  /// Derives a 32-byte key from any password or passphrase using SHA-256
  static enc.Key deriveKey(String passphrase) {
    final bytes = utf8.encode(passphrase);
    final digest = sha256.convert(bytes);
    return enc.Key(Uint8List.fromList(digest.bytes));
  }

  /// Encrypts plaintext string with a passphrase using AES-CBC with random IV
  static String encryptString(String plainText, String passphrase) {
    final key = deriveKey(passphrase);
    final iv = enc.IV.fromSecureRandom(16);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));

    final encrypted = encrypter.encrypt(plainText, iv: iv);
    // Combine IV + Ciphertext for self-contained payload
    final combined = {
      'iv': iv.base64,
      'data': encrypted.base64,
    };
    return base64Encode(utf8.encode(jsonEncode(combined)));
  }

  /// Decrypts ciphertext string with a passphrase
  static String decryptString(String encryptedBase64, String passphrase) {
    final key = deriveKey(passphrase);
    final rawJson = utf8.decode(base64Decode(encryptedBase64));
    final map = jsonDecode(rawJson) as Map<String, dynamic>;

    final iv = enc.IV.fromBase64(map['iv'] as String);
    final cipher = enc.Encrypted.fromBase64(map['data'] as String);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));

    return encrypter.decrypt(cipher, iv: iv);
  }
}
