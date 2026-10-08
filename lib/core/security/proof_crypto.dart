import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Proof for whoever sent a public order: encrypted on this device to the
/// public key their browser made, so only that browser can open it. The
/// Worker that holds it until then sees ciphertext only.
///
/// The browser decrypts with WebCrypto, so the steps match it exactly:
/// P-256 ECDH with a fresh key for each proof, HKDF-SHA256 (32 zero bytes of
/// salt, [info]) to an AES-256 key, then AES-GCM with a 12-byte IV and a
/// 128-bit tag on the end of the ciphertext.
class ProofCrypto {
  ProofCrypto._();

  static const String info = 'stm-proof-v1';

  /// The envelope the page opens: the ephemeral public key, IV, ciphertext
  /// and what the plaintext is - all base64, as JSON.
  static String encrypt(String issuerKey, Uint8List plaintext, String mime) {
    final params = ECDomainParameters('secp256r1');
    final point = params.curve.decodePoint(base64.decode(base64.normalize(issuerKey.replaceAll('-', '+').replaceAll('_', '/'))));
    if (point == null) throw const FormatException('not a P-256 public key');

    final random = FortunaRandom()..seed(KeyParameter(_randomBytes(32)));
    final generator = ECKeyGenerator()..init(ParametersWithRandom(ECKeyGeneratorParameters(params), random));
    final pair = generator.generateKeyPair();
    final ephemeral = pair.privateKey as ECPrivateKey;
    final ephemeralPublic = pair.publicKey as ECPublicKey;

    final shared = (ECDHBasicAgreement()..init(ephemeral)).calculateAgreement(ECPublicKey(point, params));
    final hkdf = HKDFKeyDerivator(SHA256Digest())
      ..init(HkdfParameters(_fixed32(shared), 32, Uint8List(32), Uint8List.fromList(utf8.encode(info))));
    final key = hkdf.process(Uint8List(0));

    final iv = _randomBytes(12);
    final gcm = GCMBlockCipher(AESEngine())..init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    final ciphertext = gcm.process(plaintext);

    return jsonEncode({
      'v': 1,
      'epk': base64.encode(ephemeralPublic.Q!.getEncoded(false)),
      'iv': base64.encode(iv),
      'ct': base64.encode(ciphertext),
      'mime': mime,
    });
  }

  /// A key pair for receiving proof in this app, as the page makes in a
  /// browser: the private scalar (hex) to keep, and the public point (base64)
  /// to send with each order.
  static ({String privateHex, String publicKey}) newKeyPair() {
    final params = ECDomainParameters('secp256r1');
    final random = FortunaRandom()..seed(KeyParameter(_randomBytes(32)));
    final pair = (ECKeyGenerator()..init(ParametersWithRandom(ECKeyGeneratorParameters(params), random))).generateKeyPair();
    return (
      privateHex: (pair.privateKey as ECPrivateKey).d!.toRadixString(16),
      publicKey: base64.encode((pair.publicKey as ECPublicKey).Q!.getEncoded(false)),
    );
  }

  /// Opens proof encrypted to this app's key: the bytes, and what they are.
  /// Throws if it was not for this key, or has been tampered with.
  static ({Uint8List bytes, String mime}) decrypt(String envelope, String privateHex) {
    final env = jsonDecode(envelope) as Map<String, dynamic>;
    final params = ECDomainParameters('secp256r1');
    final private = ECPrivateKey(BigInt.parse(privateHex, radix: 16), params);
    final epk = ECPublicKey(params.curve.decodePoint(base64.decode(env['epk'] as String)), params);
    final shared = (ECDHBasicAgreement()..init(private)).calculateAgreement(epk);
    final key = (HKDFKeyDerivator(SHA256Digest())
          ..init(HkdfParameters(_fixed32(shared), 32, Uint8List(32), Uint8List.fromList(utf8.encode(info)))))
        .process(Uint8List(0));
    final gcm = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), 128, base64.decode(env['iv'] as String), Uint8List(0)));
    return (bytes: gcm.process(base64.decode(env['ct'] as String)), mime: env['mime'] as String? ?? 'image/jpeg');
  }

  /// The shared secret as WebCrypto gives it: the x coordinate, 32 bytes.
  static Uint8List _fixed32(BigInt n) {
    final out = Uint8List(32);
    var v = n;
    for (var i = 31; i >= 0; i--) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v = v >> 8;
    }
    return out;
  }

  static Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }
}
