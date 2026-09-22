
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
  /// Empty would mean every manifest is treated as unverified, which blocks
  /// installing but never notifying. Replacing this value changes which
  /// releases devices will accept, so it changes only when the release key
  /// does.
  static const String publicModulusHex =
      'bff1d51e548b8eb77445bf9cf2caad3fd3c5cd2775d105040cd68f93784f3bbfea74f781b142fc972815a68aad5d96c72a1c5c0fb7343bf1071d93a012549ba13e1521ba359ff38f3438b2a4d6a2b80893cc8d10ca029f9ab0d257aca17e1f55370f6831cc2e8bd12d3a251440dab34c68859f76f61ce1b75b13ec692bff6024671c1b36c91ce93c59adcffaa5bb67c0c3ca5c77145cc62f1e56e9a267a995283916bace015e8cb8983f58e7bdd8b2207dc80588c7d1132370dc27cb119792167dd30b5c12bf2389028680ae7c0144ce39c2175486b8b84673e4416b45664592f2840fb7059bd4daeed5d2ea03867ac629c9c20850b977af69631c071be1d522b1badb81d0c0a3d3d3d4bd7be59a12e42c3cf1c83a1e696f57612b691260d7021ddd48fcf823343351294aa3e500ad545e3c3027bc82888d61bdb7030a23ae14c076b6454dd942be19414334c68652ad2cfa70944e51548302d1215929ef6d8d3ebd7e8887d9713ea584deaf4a5b7f5bb8eab9c59a508c73a1d64b8a7f4e21c6138eb75609fc4b480c2a79448754e6b5d4e4f1fd5893e2ad13bf3212844b0144794055623e98fb3ab33712cb3012df73a3e56f7693995cb6056d1ea17f5f6f98a3c40e86bc5f1911ea297183c1a0ce6feb3c33bbe1d188987eb18aaa17082ff64a7fd2cf91415bb24a817c09f66a0e027c3245859016a2c6c6510e48f5bccf59';
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
