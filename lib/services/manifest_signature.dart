
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

/// Checks that an update manifest was published by whoever holds the release
/// signing key.
///
/// The manifest decides what the app downloads and installs. Fetching it over
/// HTTPS proves it came from the site; it does not prove the site was not
/// changed. A signature does, because verifying it needs only the public half,
/// which ships inside the app, while producing one needs the private half,
/// which never leaves the release machine.
///
/// Signatures are RSASSA-PKCS1-v1_5 over SHA-256, as produced by:
///   openssl dgst -sha256 -sign subtask-manifest-key.pem -out latest.json.sig latest.json
class ManifestSignature {
  /// Public half of the release signing key, as modulus and exponent.
  ///
  /// Empty until the key is generated, and empty means every manifest is
  /// treated as unverified - which blocks installing, never notifying.
  static const String publicModulusHex = '';
  static const int publicExponent = 65537;

  static bool get hasKey => publicModulusHex.isNotEmpty;

  /// Whether [signature] is a signature of exactly [manifestBytes].
  ///
  /// Takes the bytes as served rather than a parsed manifest: a signature
  /// covers bytes, and re-encoding a decoded manifest would not reproduce them.
  static bool verify({
    required Uint8List manifestBytes,
    required Uint8List? signature,
  }) {
    if (!hasKey || signature == null || signature.isEmpty) return false;
    try {
      final key = RSAPublicKey(
        BigInt.parse(publicModulusHex, radix: 16),
        BigInt.from(publicExponent),
      );
      final verifier = RSASigner(SHA256Digest(), '0609608648016503040201')
        ..init(false, PublicKeyParameter<RSAPublicKey>(key));
      return verifier.verifySignature(manifestBytes, RSASignature(signature));
    } catch (e) {
      // A malformed signature is an unverified manifest, not a crash.
      if (kDebugMode) print('ManifestSignature.verify: $e');
      return false;
    }
  }
}
