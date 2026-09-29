import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/core/security/patreon_access.dart';
import 'package:orders_app/services/patreon_channel.dart';
import 'package:orders_app/services/update_downloader.dart';
import 'package:orders_app/services/update_service.dart';

/// Patreon early-access builds: served by the Worker to requests carrying the
/// code, offered beside public releases, and numbered so the public release
/// that follows still counts as an update.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A stand-in code, so the real one never appears in the test suite.
  const code = 'TESTCODE';
  final worker = 'https://${PatreonChannel.host}';

  Uint8List manifest(String version, {String? url}) => Uint8List.fromList(utf8.encode(jsonEncode({
        'version': version,
        'downloads': {
          'windows': {
            'url': url ?? '$worker/patreon/download/subTaskManager-Windows-Release.zip',
            'sha256': 'a' * 64,
          },
        },
      })));

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PatreonAccess.debugDigests = {PatreonAccess.digestOf(code)};
    UpdateService.fetch = (_) async => null;
    PatreonChannel.fetch = (_, __) async => null;
  });

  tearDown(() {
    PatreonAccess.debugDigests = null;
    UpdateService.fetch = (_) async => null;
    PatreonChannel.fetch = (_, __) async => null;
  });

  group('version order', () {
    test('an early build sits between the release before it and its own release', () {
      expect(UpdateService.isNewer('1.1.0-p1', '1.0.1'), isTrue);
      expect(UpdateService.isNewer('1.1.0-p1', '1.0.0'), isTrue);
      expect(UpdateService.isNewer('1.1.0', '1.1.0-p1'), isTrue,
          reason: 'the public release must be offered to someone on the Patreon build');
      expect(UpdateService.isNewer('1.1.0-p1', '1.1.0'), isFalse);
    });

    test('later early builds of the same version come after earlier ones', () {
      expect(UpdateService.isNewer('1.1.0-p2', '1.1.0-p1'), isTrue);
      expect(UpdateService.isNewer('1.1.0-p10', '1.1.0-p9'), isTrue);
      expect(UpdateService.compareVersions('1.1.0-p1', '1.1.0-p1'), 0);
    });

    test('build metadata after a plus does not count', () {
      expect(UpdateService.compareVersions('1.0.0+66', '1.0.0'), 0);
      expect(UpdateService.compareVersions('1.0.0+66', '1.0.0+65'), 0);
    });
  });

  group('the kept code', () {
    test('a valid code is kept, trimmed and upper-cased', () async {
      await PatreonChannel.remember('  testcode ');
      expect(await PatreonChannel.storedCode(), code);
    });

    test('an invalid code is not kept', () async {
      await PatreonChannel.remember('NOPE');
      expect(await PatreonChannel.storedCode(), isNull);
    });

    test('a kept code that no longer unlocks anything is not used', () async {
      await PatreonChannel.remember(code);
      PatreonAccess.debugDigests = {PatreonAccess.digestOf('NEWCODE')};
      expect(await PatreonChannel.storedCode(), isNull);
    });
  });

  group('checking', () {
    test('without a kept code, the Patreon channel is never asked', () async {
      UpdateService.fetch = (_) async => manifest('9.9.0');
      var asked = false;
      PatreonChannel.fetch = (_, __) async {
        asked = true;
        return null;
      };

      final update = await UpdateService.check(force: true);

      expect(update?.version, '9.9.0');
      expect(asked, isFalse);
    });

    test('a newer early build is offered, carrying the code for its download', () async {
      await PatreonChannel.remember(code);
      UpdateService.fetch = (_) async => manifest('9.9.0');
      String? sentCode;
      PatreonChannel.fetch = (url, c) async {
        sentCode = c;
        return url.path.endsWith('.sig') ? null : manifest('9.10.0-p1');
      };

      final update = await UpdateService.check(force: true);

      expect(update?.version, '9.10.0-p1');
      expect(update?.accessCode, code);
      expect(sentCode, code);
    });

    test('once its public release is out, that is offered instead', () async {
      await PatreonChannel.remember(code);
      UpdateService.fetch = (_) async => manifest('9.10.0');
      PatreonChannel.fetch = (url, _) async =>
          url.path.endsWith('.sig') ? null : manifest('9.10.0-p1');

      final update = await UpdateService.check(force: true);

      expect(update?.version, '9.10.0');
      expect(update?.accessCode, isNull, reason: 'a public release needs no code');
    });

    test('an early build is still offered when the public manifest cannot be reached', () async {
      await PatreonChannel.remember(code);
      PatreonChannel.fetch = (url, _) async =>
          url.path.endsWith('.sig') ? null : manifest('9.10.0-p1');

      final update = await UpdateService.check(force: true);

      expect(update?.version, '9.10.0-p1');
    });
  });

  group('downloading', () {
    late Directory dir;
    final payload = utf8.encode('pretend installer');
    final digest = sha256.convert(payload).toString();

    setUp(() async => dir = await Directory.systemTemp.createTemp('patreon_download_test'));
    tearDown(() async {
      UpdateDownloader.opener = (_) async => throw StateError('not stubbed');
      UpdateDownloader.patreonOpener = (_, __) async => throw StateError('not stubbed');
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    AppUpdate build(String url, {String? accessCode}) => AppUpdate(
          version: '9.10.0-p1',
          downloadUrl: url,
          sha256: digest,
          manifestVerified: true,
          accessCode: accessCode,
        );

    DownloadSource source() => DownloadSource(Stream.value(payload), contentLength: payload.length);

    test('an early build is fetched from the Worker with the code', () async {
      String? sentCode;
      UpdateDownloader.patreonOpener = (_, c) async {
        sentCode = c;
        return source();
      };

      final result = await UpdateDownloader.download(
        update: build('$worker/patreon/download/x.zip', accessCode: code),
        into: dir,
      );

      expect(result.isReady, isTrue);
      expect(sentCode, code);
    });

    test('the code is never sent anywhere but the Worker', () async {
      var sentCode = false;
      UpdateDownloader.patreonOpener = (_, __) async {
        sentCode = true;
        return source();
      };
      UpdateDownloader.opener = (_) async => source();

      final result = await UpdateDownloader.download(
        update: build(
          'https://github.com/howardmurdock-oss/subtask-manager/releases/latest/download/x.zip',
          accessCode: code,
        ),
        into: dir,
      );

      expect(result.isReady, isTrue);
      expect(sentCode, isFalse);
    });
  });
}
