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
