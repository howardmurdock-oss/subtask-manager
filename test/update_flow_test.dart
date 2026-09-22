import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/services/update_downloader.dart';
import 'package:orders_app/services/update_installer.dart';
import 'package:orders_app/services/update_flow.dart';
import 'package:orders_app/services/update_service.dart';

/// The state behind the update banner and the version card, which are two
/// views of one thing: a second download of the same 65MB file, or a progress
/// bar that knows nothing about a cancellation elsewhere, is the failure this
/// is arranged to avoid.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final payload = utf8.encode('an installer, for the sake of argument' * 32);
  final digest = sha256.convert(payload).toString();

  AppUpdate offered({bool verified = true, String? sha}) => AppUpdate(
        version: '9.9.9',
        downloadUrl:
            'https://github.com/howardmurdock-oss/subtask-manager/releases/latest/download/subTaskManager-Android-Release.apk',
        sha256: sha ?? digest,
        sizeBytes: payload.length,
        manifestVerified: verified,
      );

  final flow = UpdateFlow.instance;

  late Directory workDir;
  late List<File> installed;
  late InstallOutcome installOutcome;
  var quitCalls = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    workDir = await Directory.systemTemp.createTemp('update_flow_test');
    UpdateFlow.downloadDirectory = () async => workDir;

    // Never the real installer: on Windows it replaces the folder the running
    // executable sits in, which under test is the test runner itself.
    installed = [];
    installOutcome = InstallOutcome.handedOff;
    quitCalls = 0;
    UpdateFlow.installer = (file) async {
      installed.add(file);
      return InstallResult(installOutcome);
    };
    UpdateFlow.quitApp = () => quitCalls++;

    flow.resetForTest();
    // Served in pieces: cancellation is checked between chunks, so a
    // single-chunk stream would finish before anyone could cancel it.
    UpdateDownloader.opener = (_) async => DownloadSource(
          Stream.fromIterable([
            for (var i = 0; i < payload.length; i += 64)
              payload.sublist(i, i + 64 > payload.length ? payload.length : i + 64),
          ]),
          contentLength: payload.length,
        );
  });

  test('an offer starts idle and says what it is', () {
    flow.offer(offered());

    expect(flow.phase, UpdatePhase.offered);
    expect(flow.update!.version, '9.9.9');
    expect(flow.progress, isNull);
  });

  test('dismissing hides the prompt without skipping the version', () async {
    flow.offer(offered());
    flow.dismiss();

    expect(flow.phase, UpdatePhase.dismissed);
    expect(await UpdateService.isSkipped('9.9.9'), isFalse,
        reason: 'Later means later, not never');
  });

  test('skipping silences that version for good', () async {
    flow.offer(offered());
    await flow.skip();

    expect(flow.phase, UpdatePhase.dismissed);
    expect(await UpdateService.isSkipped('9.9.9'), isTrue);
    expect(await UpdateService.isSkipped('9.9.10'), isFalse,
        reason: 'the next version is a different decision');
  });

  test('a download that does not match the release reports it plainly', () async {
    flow.offer(offered(sha: 'f' * 64));

    await flow.downloadAndInstall();

    expect(flow.phase, UpdatePhase.failed);
    expect(flow.message, contains('did not match'));
  });

  test('an unverified release is never downloaded', () async {
    var opened = false;
    UpdateDownloader.opener = (_) async {
      opened = true;
      return DownloadSource(Stream.value(payload));
    };
    flow.offer(offered(verified: false));

    expect(flow.canInstallInApp, isFalse);
    await flow.downloadAndInstall();

    expect(opened, isFalse);
    expect(flow.phase, UpdatePhase.failed);
    expect(flow.message, contains('verified'));
  });

  test('cancelling returns to the offer rather than an error', () async {
    flow.offer(offered());
    // Cancel as soon as the first bytes arrive. Removed afterwards: the flow
    // is a singleton, so a listener left attached here cancels the downloads
    // of every test that follows.
    void cancelOnFirstBytes() {
      if (flow.phase == UpdatePhase.downloading && (flow.progress ?? 0) > 0) {
        flow.cancelDownload();
      }
    }

    flow.addListener(cancelOnFirstBytes);
    await flow.downloadAndInstall();
    flow.removeListener(cancelOnFirstBytes);

    expect(flow.phase, UpdatePhase.offered, reason: 'the update is still there to take');
    expect(flow.message, contains('cancelled'));
  });

  test('a verified download is installed, and the app steps aside for it', () async {
    flow.offer(offered());

    await flow.downloadAndInstall();

    expect(installed, hasLength(1), reason: 'the downloaded file is what gets installed');
    expect(await installed.single.readAsBytes(), payload);
    // On Windows the swap waits for this process to release its own files, so
    // closing is part of installing rather than something left to the user.
    expect(quitCalls, Platform.isWindows ? 1 : 0);
  });

  test('an install that needs permission says so instead of failing', () async {
    installOutcome = InstallOutcome.permissionRequired;
    flow.offer(offered());

    await flow.downloadAndInstall();

    expect(flow.phase, UpdatePhase.permissionRequired);
    expect(quitCalls, 0, reason: 'nothing was installed, so nothing should close');
  });

  test('notifies its listeners as the state moves', () async {
    var notifications = 0;
    void count() => notifications++;
    flow.addListener(count);

    flow.offer(offered(sha: 'f' * 64));
    await flow.downloadAndInstall();
    flow.removeListener(count);

    expect(notifications, greaterThan(2),
        reason: 'the banner and the card both redraw from these');
  });

  tearDown(() async {
    flow.resetForTest();
    UpdateDownloader.opener = (_) async => throw StateError('not stubbed');
    if (await workDir.exists()) await workDir.delete(recursive: true);
  });
}
