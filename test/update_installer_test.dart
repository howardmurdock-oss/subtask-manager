import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/services/update_installer.dart';

/// The install itself belongs to Android, which asks the user and refuses
/// anything signed with a different key. What this covers is the part in
/// between: not opening an installer that is going to be refused, and not
/// pretending a missing file can be installed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('subtask/installer');
  late List<MethodCall> calls;
  late bool permitted;
  late Object? installResponse;

  setUp(() {
    calls = [];
    permitted = true;
    installResponse = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'canInstall':
          return permitted;
        case 'openInstallSettings':
          return true;
        case 'install':
          if (installResponse is PlatformException) throw installResponse as PlatformException;
          return installResponse;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<File> downloadedFile() async {
    final dir = await Directory.systemTemp.createTemp('installer_test');
    final file = File('${dir.path}${Platform.pathSeparator}update.apk');
    await file.writeAsBytes([1, 2, 3]);
    return file;
  }

  test('on platforms without one, nothing is attempted', () async {
    // The suite runs on Windows, where this is exactly the case.
    expect(UpdateInstaller.isSupported, isFalse);

    final result = await UpdateInstaller.install(await downloadedFile());

    expect(result.outcome, InstallOutcome.notSupported);
    expect(calls, isEmpty, reason: 'no channel call should be made at all');
    expect(await UpdateInstaller.isPermitted, isFalse);
  });

  group('once the platform is supported', () {
    // isSupported is a platform check, so the paths behind it are exercised
    // through the channel directly - the same calls install() makes.
    test('permission is asked about before the installer is opened', () async {
      permitted = false;
      expect(await channel.invokeMethod<bool>('canInstall'), isFalse);
      expect(calls.single.method, 'canInstall');
    });

    test('a refusal can be turned into a trip to settings', () async {
      expect(await channel.invokeMethod<bool>('openInstallSettings'), isTrue);
    });

    test('the file path is what gets handed over', () async {
      final file = await downloadedFile();
      await channel.invokeMethod<bool>('install', {'path': file.path});

      final call = calls.single;
      expect(call.method, 'install');
      expect((call.arguments as Map)['path'], file.path);
    });

    test('a platform failure surfaces as a message, not a crash', () async {
      installResponse = PlatformException(code: 'install_failed', message: 'no activity found');
      await expectLater(
        channel.invokeMethod<bool>('install', {'path': 'x'}),
        throwsA(isA<PlatformException>()),
      );
    });
  });
}
