import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';

import 'update_installer.dart';

/// Replaces a Windows installation with a newer one.
///
/// Windows ships as a portable folder, and a running .exe cannot overwrite
/// itself, so the swap happens after this process exits: the download is
/// unpacked alongside the installation, a small script waits for the app to
/// close, moves the old folder aside, moves the new one in and starts it
/// again.
///
/// The order matters. The old installation is moved rather than deleted, and
/// only removed once the new one is in place - if the move fails halfway, on a
/// locked file or an antivirus scanner holding something open, the script puts
/// the original back rather than leaving a machine with no application on it.
class WindowsUpdater {
  static bool get isSupported => !kIsWeb && Platform.isWindows;

  /// The folder holding the running application.
  static Directory get installDirectory => File(Platform.resolvedExecutable).parent;

  /// Whether this installation can be replaced in place.
  ///
  /// A copy under Program Files is not writable without elevation, and asking
  /// for elevation to swap folders is a worse bargain than telling the user to
  /// download it themselves.
  static Future<bool> canReplaceInstallation() async {
    try {
      final probe = File('${installDirectory.path}${Platform.pathSeparator}.update-probe');
      await probe.writeAsString('probe');
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Unpacks [zip] into a sibling of the installation, and returns it.
  ///
  /// A sibling rather than a temporary directory because the swap that follows
  /// is a move: across volumes that becomes a copy of every file, which is
  /// slower and can half-finish.
  @visibleForTesting
  static Directory stagingFor(Directory installation) => Directory(
      '${installation.parent.path}${Platform.pathSeparator}'
      '${installation.uri.pathSegments.where((s) => s.isNotEmpty).last}.update');

  @visibleForTesting
  static Future<Directory> unpackBeside(File zip, Directory installation) async {
    final staging = stagingFor(installation);
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);

    final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
    await extractArchiveToDisk(archive, staging.path);

    // The zip holds the contents of the release folder, but a zip made from
    // the folder itself would nest everything one level down. Flatten that
    // rather than installing a folder containing a folder.
    final entries = await staging.list().toList();
    if (entries.length == 1 && entries.single is Directory) {
      return entries.single as Directory;
    }
    return staging;
  }

  /// The script that performs the swap once this process has exited.
  @visibleForTesting
  static String swapScript({
    required int pid,
    required String staging,
    required String target,
    required String executable,
  }) =>
      """
# Written by (sub)Task Manager to replace itself. Safe to delete.
\$ErrorActionPreference = 'Stop'

# A failed swap used to leave the app closed and nothing to look at. Whatever
# happens here is written down; the log is removed again on success.
\$log = "\$PSCommandPath.log"
function Say(\$m) {
    Add-Content -LiteralPath \$log -Value "\$((Get-Date).ToString('HH:mm:ss')) \$m"
}

# Nothing may hold the installation open - including this script. Windows
# refuses to move a directory that any process has as its working directory,
# and this script inherits the app's, which is the installation itself. That
# failed the very first move, so the update did nothing at all.
Set-Location -LiteralPath \$env:TEMP
[Environment]::CurrentDirectory = \$env:TEMP

# Wait for the app to close. Files under the installation stay locked until it
# does, and a move would fail against them.
Say 'waiting for the app to close (pid $pid)'
for (\$i = 0; \$i -lt 120; \$i++) {
    if (-not (Get-Process -Id $pid -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 500
}

\$backup = '$target.old'
if (Test-Path -LiteralPath \$backup) { Remove-Item -LiteralPath \$backup -Recurse -Force }

# Move the old installation aside first. If anything below fails, it goes back:
# a failed update must leave the machine with the version it started with.
# Scanners and indexers can hold a file open for a moment after the process
# exits, so this is worth a few attempts before calling it a failure.
\$movedAside = \$false
for (\$i = 0; \$i -lt 10 -and -not \$movedAside; \$i++) {
    try {
        Move-Item -LiteralPath '$target' -Destination \$backup -Force
        \$movedAside = \$true
    } catch {
        Say "could not move the installation aside: \$_"
        Start-Sleep -Milliseconds 700
    }
}

if (-not \$movedAside) {
    # Nothing has been touched. Clear the download rather than leaving a copy
    # of the new version sitting beside the old one forever.
    Say 'giving up; the installation is untouched'
    Remove-Item -LiteralPath '$staging' -Recurse -Force -ErrorAction SilentlyContinue
    try { Start-Process -FilePath '$executable' } catch { Say "restart failed: \$_" }
    exit 1
}

try {
    Move-Item -LiteralPath '$staging' -Destination '$target' -Force
} catch {
    Say "could not move the new version in: \$_"
    Move-Item -LiteralPath \$backup -Destination '$target' -Force
    try { Start-Process -FilePath '$executable' } catch { Say "restart failed: \$_" }
    exit 1
}

# The update is already in place by here. A relaunch that fails is a nuisance;
# it must not stop the old copy being cleared, or leave the user without the
# new version running and no explanation.
Say 'installed'
try {
    Start-Process -FilePath '$executable'
} catch {
    Say "update installed, but the app could not be restarted: \$_"
}

Remove-Item -LiteralPath \$backup -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath \$log -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath \$PSCommandPath -Force -ErrorAction SilentlyContinue
""";

  /// The download left behind by an update that never completed, if there is
  /// one.
  ///
  /// A swap that fails leaves the unpacked release sitting beside the
  /// installation, and the app looks - from the inside - exactly as it did
  /// before: same version, no message, nothing to suggest anything happened.
  /// Two real updates failed that way before anyone could say why.
  static Future<String?> unfinishedUpdate() => probeForUnfinishedUpdate();

  /// The probe itself, swapped out by tests that need a leftover to exist.
  @visibleForTesting
  static Future<String?> Function() probeForUnfinishedUpdate = _unfinishedUpdate;

  static Future<String?> _unfinishedUpdate() async {
    if (!isSupported) return null;
    try {
      return await unfinishedUpdateBeside(installDirectory);
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static Future<String?> unfinishedUpdateBeside(Directory installation) async {
    final staging = stagingFor(installation);
    return await staging.exists() ? staging.path : null;
  }

  /// Removes a leftover download. The next attempt re-fetches it: what was
  /// unpacked cannot be checked against the published digest, which covers the
  /// archive rather than the folder it became.
  static Future<bool> discardUnfinished(String path) async {
    try {
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Unpacks the download and hands the swap to a detached script.
  ///
  /// Returns once the script is running; the caller closes the app, which is
  /// what lets the swap proceed.
  static Future<InstallResult> install(File zip) async {
    if (!isSupported) return const InstallResult(InstallOutcome.notSupported);
    if (!await zip.exists()) {
      return const InstallResult(InstallOutcome.failed, detail: 'the download is no longer there');
    }
    if (!await canReplaceInstallation()) {
      return const InstallResult(
        InstallOutcome.failed,
        detail: 'this copy cannot be replaced automatically - it is in a folder this app '
            'cannot write to. Download it and unpack it yourself.',
      );
    }

    try {
      final installation = installDirectory;
      final staging = await unpackBeside(zip, installation);

      final script = File('${Directory.systemTemp.path}${Platform.pathSeparator}'
          'subtask-update-${DateTime.now().millisecondsSinceEpoch}.ps1');
      await script.writeAsString(swapScript(
        pid: pid,
        staging: staging.path,
        target: installation.path,
        executable: Platform.resolvedExecutable,
      ));

      await Process.start(
        'powershell.exe',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script.path],
        mode: ProcessStartMode.detached,
        // Anywhere but the installation: a child process inherits this app's
        // working directory, and a directory held open by any process cannot
        // be moved.
        workingDirectory: Directory.systemTemp.path,
      );
      return const InstallResult(InstallOutcome.handedOff);
    } catch (e) {
      return InstallResult(InstallOutcome.failed, detail: '$e');
    }
  }
}
