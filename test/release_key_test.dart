import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/services/manifest_signature.dart';
import 'package:orders_app/services/update_service.dart';

/// The key compiled into the app, against a manifest signed by the real
/// release key.
///
/// The unit tests generate their own key pair, which proves the verifier works
/// but says nothing about whether *this* app would accept *these* releases. A
/// mismatch here - a mistyped modulus, a key regenerated and not re-embedded -
/// would leave every device silently refusing to install anything.
///
/// The fixtures are a manifest as served and its detached signature. Neither
/// is secret; the private key that produced the signature is not here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fixtures = Directory('test/fixtures');
  final manifestFile = File('${fixtures.path}/signed_manifest.json');
  final signatureFile = File('${fixtures.path}/signed_manifest.sig');

  test('a manifest signed by the release key is accepted', () {
    final manifest = manifestFile.readAsBytesSync();
    final signature = signatureFile.readAsBytesSync();

    expect(ManifestSignature.hasKey, isTrue, reason: 'no public key compiled in');
    expect(
      ManifestSignature.verify(manifestBytes: manifest, signature: signature),
      isTrue,
      reason: 'releases signed with the real key must verify against the shipped key',
    );
  });

  test('the same manifest with one byte changed is not', () {
    final manifest = manifestFile.readAsBytesSync();
    final signature = signatureFile.readAsBytesSync();

    // Point the download at a different version - the kind of edit that would
    // matter, rather than a corrupted byte.
    final tampered = Uint8List.fromList(
      utf8.encode(utf8.decode(manifest).replaceFirst('"version"', '"Version"')),
    );

    expect(
      ManifestSignature.verify(manifestBytes: tampered, signature: signature),
      isFalse,
    );
  });

  test('the signed manifest is one the app can actually read', () {
    final update = UpdateService.parseManifest(
      utf8.decode(manifestFile.readAsBytesSync()),
      currentVersion: '0.0.1',
      platformKey: 'windows',
      manifestVerified: true,
    );

    expect(update, isNotNull);
    expect(update!.downloadUrl, isNotNull);
    expect(update.sha256, isNotNull,
        reason: 'without a digest the downloader refuses, signature or not');
  });
}
