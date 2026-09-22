import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:orders_app/services/manifest_signature.dart';
import 'package:orders_app/services/update_downloader.dart';
import 'package:orders_app/services/update_service.dart';

/// The manifest decides what gets downloaded and installed. HTTPS proves it
/// came from the site; only a signature proves the site was not changed.
///
/// These sign with a real key pair generated here rather than a stub, so the
/// verifier is exercised against genuine RSA signatures - including one made
/// by the wrong key, which is the case that matters.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> pair;
  late AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> otherPair;

  AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> generate() {
    final random = SecureRandom('Fortuna')
      ..seed(KeyParameter(Uint8List.fromList(
          List<int>.generate(32, (_) => Random.secure().nextInt(256)))));
    final generator = RSAKeyGenerator()
      ..init(ParametersWithRandom(
        // 1024 keeps the test quick; the published key is 4096 and the
        // verifier does not care either way.
        RSAKeyGeneratorParameters(BigInt.parse('65537'), 1024, 12),
        random,
      ));
    final generated = generator.generateKeyPair();
    return AsymmetricKeyPair(
      generated.publicKey as RSAPublicKey,
      generated.privateKey as RSAPrivateKey,
    );
  }

  Uint8List sign(Uint8List message, RSAPrivateKey key) {
    final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(key));
    return signer.generateSignature(message).bytes;
  }

  /// The verifier reads its key from a compile-time constant, so these check
  /// the same logic against a key provided here.
  bool verifyWith(RSAPublicKey key, Uint8List message, Uint8List? signature) {
    if (signature == null) return false;
    try {
      final verifier = RSASigner(SHA256Digest(), '0609608648016503040201')
        ..init(false, PublicKeyParameter<RSAPublicKey>(key));
      return verifier.verifySignature(message, RSASignature(signature));
    } catch (_) {
      return false;
    }
  }

  setUpAll(() {
    pair = generate();
    otherPair = generate();
  });

  final manifest = Uint8List.fromList(utf8.encode(jsonEncode({
    'version': '9.9.9',
    'downloads': {
      'windows': {'url': 'https://github.com/x/y.zip', 'sha256': 'a' * 64}
    }
  })));

  test('a signature from the release key verifies', () {
    final signature = sign(manifest, pair.privateKey);
    expect(verifyWith(pair.publicKey, manifest, signature), isTrue);
  });

  test('a signature from any other key does not', () {
    final signature = sign(manifest, otherPair.privateKey);
    expect(verifyWith(pair.publicKey, manifest, signature), isFalse,
        reason: 'anyone can sign a manifest; only one key is ours');
  });

  test('a manifest altered after signing does not verify', () {
    final signature = sign(manifest, pair.privateKey);
    final tampered = Uint8List.fromList(utf8.encode(
        utf8.decode(manifest).replaceFirst('9.9.9', '9.9.8')));
    expect(verifyWith(pair.publicKey, tampered, signature), isFalse);
  });

  test('rubbish in place of a signature is refused, not thrown', () {
    expect(verifyWith(pair.publicKey, manifest, Uint8List.fromList([1, 2, 3])), isFalse);
    expect(verifyWith(pair.publicKey, manifest, Uint8List(0)), isFalse);
    expect(verifyWith(pair.publicKey, manifest, null), isFalse);
  });

  test('with no key compiled in, nothing is treated as verified', () {
    // This is the state before the release key exists: the app still reports
    // updates, it just will not install them.
    expect(
      ManifestSignature.verify(manifestBytes: manifest, signature: Uint8List(64)),
      isFalse,
    );
  });

  test('an unverified manifest is never downloaded from', () async {
    final result = await UpdateDownloader.download(
      update: AppUpdate(
        version: '9.9.9',
        downloadUrl:
            'https://github.com/howardmurdock-oss/subtask-manager/releases/latest/download/subTaskManager-Windows-Release.zip',
        sha256: 'b' * 64,
        // As it arrives when the signature is missing or wrong.
        manifestVerified: false,
      ),
      into: Directory.systemTemp,
    );

    expect(result.outcome, UpdateDownloadOutcome.unverifiedManifest);
    expect(result.file, isNull);
  });
}
