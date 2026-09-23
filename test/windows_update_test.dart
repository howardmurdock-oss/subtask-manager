import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/services/windows_updater.dart';

/// Replacing an application with itself, which has exactly one acceptable
/// failure mode: the machine keeps the version it already had.
///
/// The swap script is run for real here rather than inspected, because "moves
/// the folder, puts it back if that fails" is a claim about what PowerShell
/// does, not about what the string contains.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('windows_update_test');
  });

  tearDown(() async {
    if (await root.exists()) {
      try {
        await root.delete(recursive: true);
      } catch (_) {
        // A swap script may still hold a handle; the temp folder will go.
      }
    }
  });

  /// An "installation": a folder with a file whose contents say which version
  /// it is.
  Future<Directory> installation(String version) async {
    final dir = Directory('${root.path}${Platform.pathSeparator}app');
    await dir.create(recursive: true);
    await File('${dir.path}${Platform.pathSeparator}version.txt').writeAsString(version);
    await File('${dir.path}${Platform.pathSeparator}app.exe').writeAsString('binary $version');
    return dir;
  }

  /// A release zip holding the contents of a folder, as the build produces.
  Future<File> releaseZip(String version) async {
    final source = Directory('${root.path}${Platform.pathSeparator}build-$version');
    await source.create(recursive: true);
    await File('${source.path}${Platform.pathSeparator}version.txt').writeAsString(version);
    await File('${source.path}${Platform.pathSeparator}app.exe').writeAsString('binary $version');

    final zip = File('${root.path}${Platform.pathSeparator}release-$version.zip');
    final encoder = ZipFileEncoder();
    encoder.create(zip.path);
    await encoder.addDirectory(source, includeDirName: false);
    await encoder.close();
    return zip;
  }

  test('a release unpacks beside the installation, not inside it', () async {
    final installed = await installation('1.0.0');
    final staging = await WindowsUpdater.unpackBeside(await releaseZip('2.0.0'), installed);

    expect(staging.path, isNot(installed.path));
    expect(
      await File('${staging.path}${Platform.pathSeparator}version.txt').readAsString(),
      '2.0.0',
    );
    // Same volume, so the swap is a move rather than a copy of every file.
    expect(staging.parent.path, installed.parent.path);
    expect(await File('${installed.path}${Platform.pathSeparator}version.txt').readAsString(),
        '1.0.0',
        reason: 'unpacking must not touch the running installation');
  });

  // The swap is a PowerShell script operating on Windows paths. The cloud
  // builders run the same suite on macOS and Linux, where there is nothing for
  // these to exercise - and a failure there is a failure to publish, not a
  // finding about the updater.
  final windowsOnly =
      Platform.isWindows ? null : 'the Windows swap only runs on Windows';

  group('the swap script', () {
    /// Runs the script to completion with no app to wait for.
    Future<ProcessResult> runSwap({
      required Directory installed,
      required Directory staging,
      String? executable,
      String? from,
    }) async {
      final script = File('${root.path}${Platform.pathSeparator}swap.ps1');
      await script.writeAsString(WindowsUpdater.swapScript(
        // A pid that is not running, so it proceeds immediately. Waiting for
        // an exit is covered by the app quitting, which a test cannot do.
        pid: 999999,
        staging: staging.path,
        target: installed.path,
        // A real executable that exits immediately: the script relaunches
        // whatever it is given, and a path that does not exist would only
        // test the failure branch.
        executable: executable ?? r'C:\Windows\System32\where.exe',
      ));
      return Process.run(
        'powershell.exe',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script.path],
        // Where the script is started from is the whole point of one of these
        // tests, so it is not left to whatever the runner happens to use.
        workingDirectory: from ?? root.path,
      );
    }

    test('replaces the installation with the new version', () async {
      final installed = await installation('1.0.0');
      final staging = await WindowsUpdater.unpackBeside(await releaseZip('2.0.0'), installed);

      await runSwap(installed: installed, staging: staging);

      expect(await File('${installed.path}${Platform.pathSeparator}version.txt').readAsString(),
          '2.0.0');
      expect(await Directory('${installed.path}.old').exists(), isFalse,
          reason: 'the old copy is cleared once the new one is in place');
    });

    test('survives being started from inside the folder it replaces', () async {
      // What actually happened on the first real update: the app hands the
      // swap to a detached process, which inherits the app's working
      // directory - the installation. Windows will not move a directory that
      // any process holds open, so the first move failed and the update
      // silently did nothing.
      final installed = await installation('1.0.0');
      final staging = await WindowsUpdater.unpackBeside(await releaseZip('2.0.0'), installed);

      final result = await runSwap(
        installed: installed,
        staging: staging,
        from: installed.path,
      );

      expect(result.exitCode, 0, reason: result.stdout.toString() + result.stderr.toString());
      expect(await File('${installed.path}${Platform.pathSeparator}version.txt').readAsString(),
          '2.0.0');
    });

    test('a failure leaves the installation, a log and no download behind', () async {
      final installed = await installation('1.0.0');
      final staging = Directory('${root.path}${Platform.pathSeparator}app.update');
      await staging.create(recursive: true);
      await File('${staging.path}${Platform.pathSeparator}version.txt').writeAsString('2.0.0');

      // A process holding the installation open, which is the failure the
      // retries are there to outlast - this one never lets go.
      final holder = await Process.start(
        'powershell.exe',
        ['-NoProfile', '-Command', 'Start-Sleep -Seconds 30'],
        workingDirectory: installed.path,
      );
      addTearDown(() => holder.kill());

      final result = await runSwap(installed: installed, staging: staging);

      expect(result.exitCode, isNot(0));
      expect(await File('${installed.path}${Platform.pathSeparator}version.txt').readAsString(),
          '1.0.0',
          reason: 'a failed update must leave the machine with what it had');
      expect(await staging.exists(), isFalse,
          reason: 'the download is cleared rather than left beside the installation');

      final log = File('${root.path}${Platform.pathSeparator}swap.ps1.log');
      expect(await log.exists(), isTrue,
          reason: 'a silent failure is the one thing this cannot do');
      expect(await log.readAsString(), contains('could not move the installation aside'));
    });

    test('puts the original back when the new version cannot be moved in', () async {
      final installed = await installation('1.0.0');
      // Staging that does not exist: the move in will fail after the old
      // installation has already been moved aside.
      final missing = Directory('${root.path}${Platform.pathSeparator}app.update');

      final result = await runSwap(installed: installed, staging: missing);

      expect(result.exitCode, isNot(0));
      expect(await installed.exists(), isTrue,
          reason: 'a failed update must leave the machine with what it had');
      expect(await File('${installed.path}${Platform.pathSeparator}version.txt').readAsString(),
          '1.0.0');
    });
  }, skip: windowsOnly);

  test('an installation in a folder we cannot write to is refused', () async {
    // Nothing is unpacked or swapped; the user is told to do it themselves.
    final zip = await releaseZip('2.0.0');
    expect(await zip.exists(), isTrue);
    expect(WindowsUpdater.isSupported, isTrue, reason: 'this suite runs on Windows');
    expect(await WindowsUpdater.canReplaceInstallation(), isA<bool>());
  }, skip: windowsOnly);
}
