import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:pointycastle/export.dart' as pc;

/// Passphrase encryption for sync payloads and exported packs.
///
/// Two envelope formats exist, both base64 of a JSON object:
///
/// * v1 (legacy, no `v` field): `{"iv", "data"}` - AES-256-CBC, key =
///   SHA-256(passphrase). Not authenticated: anyone relaying it can flip bits
///   in the plaintext, and a wrong key occasionally "decrypts" to garbage
///   instead of throwing.
/// * v2: `{"v": 2, "n", "ct"}` - AES-256-GCM with a 96-bit random nonce and a
///   128-bit tag, key derived from the passphrase with HKDF-SHA256 so it never
///   equals the v1 key. Any tampering, or a wrong key, fails the tag check and
///   throws, every time. The field names deliberately differ from v1 so a
///   build that only knows v1 fails on the missing `iv` rather than running
///   CBC over GCM bytes.
///
/// [decryptString] accepts both, so every build from this one on can read
/// either. What [encryptString] writes is [writeVersion].
class EncryptionHelper {
  /// The envelope [encryptString] produces.
  ///
  /// Still v1 on purpose. A build older than this one cannot read v2 and drops
  /// the message without a trace, and no device can tell which builds are
  /// reading a topic: a personal pairing secret is typed into every device
  /// that joins with it, so one v2-capable reply says nothing about the
  /// others. The switch is therefore made by release, not by negotiation:
  ///
  /// 1. This build: read v1 and v2, write v1.
  /// 2. Once every device in use is on a build that reads v2, set this to 2.
  ///    Only then does tampering in transit start being rejected.
  /// 3. Later still, sync receivers can stop accepting v1 so captured legacy
  ///    messages cannot be altered and replayed. Pack import keeps reading v1
  ///    indefinitely, since those are files users keep.
  static const int writeVersion = 1;

  static const int _v2 = 2;
  static const int _nonceLength = 12;
  static const int _tagBits = 128;
  static final Uint8List _v2Aad = _utf8('orders-app/envelope/v2');
  static final Uint8List _v2Salt = _utf8('orders-app/aead-key/v2');
  static final Uint8List _v2Info = _utf8('aes-256-gcm');
  static final Random _random = Random.secure();

  /// Derives a 32-byte key from any password or passphrase using SHA-256.
  /// This is the v1 key only.
  static enc.Key deriveKey(String passphrase) {
    final bytes = utf8.encode(passphrase);
    final digest = sha256.convert(bytes);
    return enc.Key(Uint8List.fromList(digest.bytes));
  }

  /// Encrypts [plainText] under [passphrase] in envelope [version]
  /// (default [writeVersion]).
  static String encryptString(String plainText, String passphrase,
      {int version = writeVersion}) {
    final Map<String, dynamic> envelope;
    switch (version) {
      case 1:
        envelope = _encryptV1(plainText, passphrase);
      case _v2:
        envelope = _encryptV2(plainText, passphrase);
      default:
        throw ArgumentError.value(version, 'version', 'Unknown envelope version');
    }
    return base64Encode(utf8.encode(jsonEncode(envelope)));
  }

  /// Decrypts a payload from [encryptString], in either envelope version.
  ///
  /// For a v2 envelope this throws whenever the key is wrong or any byte of
  /// the envelope was changed. A v1 envelope carries no such guarantee.
  static String decryptString(String encryptedBase64, String passphrase) {
    final rawJson = utf8.decode(base64Decode(encryptedBase64));
    final map = jsonDecode(rawJson) as Map<String, dynamic>;

    final version = map['v'];
    if (version == null) return _decryptV1(map, passphrase);
    if (version == _v2) return _decryptV2(map, passphrase);
    throw FormatException('Unsupported envelope version: $version');
  }

  static Map<String, dynamic> _encryptV1(String plainText, String passphrase) {
    final iv = enc.IV.fromSecureRandom(16);
    final encrypter =
        enc.Encrypter(enc.AES(deriveKey(passphrase), mode: enc.AESMode.cbc));
    final encrypted = encrypter.encrypt(plainText, iv: iv);
    return {'iv': iv.base64, 'data': encrypted.base64};
  }

  static String _decryptV1(Map<String, dynamic> map, String passphrase) {
    final iv = enc.IV.fromBase64(map['iv'] as String);
    final cipher = enc.Encrypted.fromBase64(map['data'] as String);
    final encrypter =
        enc.Encrypter(enc.AES(deriveKey(passphrase), mode: enc.AESMode.cbc));
    return encrypter.decrypt(cipher, iv: iv);
  }

  static Map<String, dynamic> _encryptV2(String plainText, String passphrase) {
    final nonce = Uint8List.fromList(
        List<int>.generate(_nonceLength, (_) => _random.nextInt(256)));
    final sealed =
        _gcm(true, _deriveKeyV2(passphrase), nonce).process(_utf8(plainText));
    return {'v': _v2, 'n': base64Encode(nonce), 'ct': base64Encode(sealed)};
  }

  static String _decryptV2(Map<String, dynamic> map, String passphrase) {
    final nonce = base64Decode(map['n'] as String);
    if (nonce.length != _nonceLength) {
      throw const FormatException('Bad nonce length');
    }
    final sealed = base64Decode(map['ct'] as String);
    // Throws InvalidCipherTextException unless the tag verifies.
    final opened = _gcm(false, _deriveKeyV2(passphrase), nonce).process(sealed);
    return utf8.decode(opened);
  }

  static pc.GCMBlockCipher _gcm(
      bool forEncryption, Uint8List key, Uint8List nonce) {
    return pc.GCMBlockCipher(pc.AESEngine())
      ..init(forEncryption,
          pc.AEADParameters(pc.KeyParameter(key), _tagBits, nonce, _v2Aad));
  }

  /// HKDF-SHA256 (RFC 5869) with a fixed salt, one 32-byte output block.
  static Uint8List _deriveKeyV2(String passphrase) {
    final prk = Hmac(sha256, _v2Salt).convert(_utf8(passphrase)).bytes;
    final okm = Hmac(sha256, prk).convert([..._v2Info, 1]).bytes;
    return Uint8List.fromList(okm);
  }

  static Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));
}
