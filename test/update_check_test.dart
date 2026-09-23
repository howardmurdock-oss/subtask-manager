import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/services/update_service.dart';

/// The app is distributed outside any store, so nothing tells a user they are
/// on an old build - testers have sat months apart without knowing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Deliberately far above any real version: these exercise check(), which
  // compares against the app's own version, and a fixture of '1.4.0' started
  // failing the moment the app reached 1.4.0.
  String manifest({
    String version = '9.9.0',
    String platform = 'windows',
    String url = 'https://github.com/howardmurdock-oss/subtask-manager/releases/latest/download/subTaskManager-Windows-Release.zip',
    String notes = 'https://github.com/howardmurdock-oss/subtask-manager/releases/tag/v9.9.0',
  }) =>
      jsonEncode({
        'version': version,
        'build': 45,
        'released': '2026-09-21',
        'notesUrl': notes,
        'downloads': {
          platform: {'url': url, 'sha256': 'abc', 'size': 15389545},
        },
      });

  Uint8List bytes(String body) => Uint8List.fromList(utf8.encode(body));

  AppUpdate? parse(String body, {String current = '1.3.9', String platform = 'windows'}) =>
      UpdateService.parseManifest(body, currentVersion: current, platformKey: platform);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UpdateService.fetch = (_) async => bytes(manifest());
  });

  tearDown(() => UpdateService.fetch = (_) async => null);


  group('version comparison', () {
    test('orders releases correctly', () {
      expect(UpdateService.isNewer('1.4.0', '1.3.9'), isTrue);
      expect(UpdateService.isNewer('1.3.10', '1.3.9'), isTrue,
          reason: 'string comparison would call this older');
      expect(UpdateService.isNewer('1.4.10', '1.4.9'), isTrue,
          reason: 'the first double-digit patch release');
      expect(UpdateService.isNewer('1.4.9', '1.4.10'), isFalse);
      expect(UpdateService.isNewer('1.3.9', '1.3.9'), isFalse);
      expect(UpdateService.isNewer('1.3.8', '1.3.9'), isFalse);
      expect(UpdateService.isNewer('2.0.0', '1.9.9'), isTrue);
    });

    test('a missing component is zero, not missing', () {
      expect(UpdateService.compareVersions('1.4', '1.4.0'), 0);
      expect(UpdateService.isNewer('1.4.1', '1.4'), isTrue);
    });
  });

  group('manifest', () {
    test('reports a newer version with its download', () {
      final update = parse(manifest())!;
      expect(update.version, '9.9.0');
      expect(update.downloadUrl, contains('subTaskManager-Windows-Release.zip'));
      expect(update.sizeLabel, '14.7 MB');
    });

    test('says nothing when the published version is not newer', () {
      expect(parse(manifest(version: '1.3.9')), isNull);
      expect(parse(manifest(version: '1.2.0')), isNull);
    });

    test('offers no download when the platform is not published', () {
      final update = parse(manifest(platform: 'android'), platform: 'linux')!;
      expect(update.version, '9.9.0');
      expect(update.downloadUrl, isNull, reason: 'the release notes are still worth showing');
      expect(update.notesUrl, isNotNull);
    });

    test('refuses a download link pointing somewhere else', () {
      // The manifest arrives over the network: it decides *whether* to prompt,
      // it does not get to decide where the user is sent.
      final elsewhere = parse(manifest(url: 'https://evil.example.com/app.zip'))!;
      expect(elsewhere.downloadUrl, isNull);

      final insecure = parse(manifest(url: 'http://github.com/x/app.zip'))!;
      expect(insecure.downloadUrl, isNull);
    });

    test('reads a manifest written with a byte-order mark', () {
      // PowerShell's Set-Content writes one by default, and it is invisible:
      // the manifest looked perfect while every check failed silently.
      final update = parse('﻿${manifest()}');
      expect(update?.version, '9.9.0');
    });

    test('survives rubbish', () {
      expect(parse('not json'), isNull);
      expect(parse('{}'), isNull);
      expect(parse('[]'), isNull);
      expect(parse(jsonEncode({'version': 42})), isNull);
    });
  });

  group('checking', () {
    test('does not check again within the interval', () async {
      var fetches = 0;
      UpdateService.fetch = (url) async {
        // The signature is fetched alongside the manifest; count only the
        // manifest itself.
        if (!url.path.endsWith('.sig')) fetches++;
        return bytes(manifest());
      };

      expect(await UpdateService.check(), isNotNull);
      expect(await UpdateService.check(), isNull);
      expect(fetches, 1);

      // Asking explicitly always checks.
      expect(await UpdateService.check(force: true), isNotNull);
      expect(fetches, 2);
    });

    test('skipping silences one version, not the next', () async {
      final first = await UpdateService.check();
      await UpdateService.skip(first!.version);

      // Skipping governs whether the user is interrupted...
      expect(await UpdateService.isSkipped('9.9.0'), isTrue);
      expect(await UpdateService.isSkipped('9.9.1'), isFalse);

      // ...not whether the update exists, so asking outright still finds it.
      expect((await UpdateService.check(force: true))?.version, '9.9.0');
    });

    test('a failed fetch is silent', () async {
      UpdateService.fetch = (_) async => null;
      expect(await UpdateService.check(), isNull);

      UpdateService.fetch = (_) async => throw const SocketExceptionStub();
      expect(await UpdateService.check(force: true), isNull);
    });
  });
}

class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
