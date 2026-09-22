import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// How far an install attempt got.
enum InstallOutcome {
  /// Handed to the system installer. Whether it completes is the user's
  /// decision, made in a system dialog this app does not see.
  handedOff,

  /// The app is not allowed to request installs yet. The user grants that in
  /// Android settings, which [UpdateInstaller.openPermissionSettings] opens.
  permissionRequired,

  notSupported,
  failed,
}

class InstallResult {
  const InstallResult(this.outcome, {this.detail});

  final InstallOutcome outcome;
  final String? detail;
}

/// Hands a verified download to the platform's own installer.
///
/// Deliberately the end of the line rather than the whole job: this app
/// downloads a file and offers it. The system asks the user to confirm, and
/// refuses outright anything not signed with the same key as the app already
/// installed - which is the check that actually protects them, and one no
/// amount of care here could replace.
class UpdateInstaller {
  @visibleForTesting
  static MethodChannel channel = const MethodChannel('subtask/installer');

  /// Android only. Windows replaces its own files; macOS and Linux send the
  /// user to the download page.
  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// Whether the user has allowed this app to request installs.
  static Future<bool> get isPermitted async {
    if (!isSupported) return false;
    try {
      return await channel.invokeMethod<bool>('canInstall') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the Android settings page for that permission.
  static Future<bool> openPermissionSettings() async {
    if (!isSupported) return false;
    try {
      return await channel.invokeMethod<bool>('openInstallSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<InstallResult> install(File apk) async {
    if (!isSupported) {
      return const InstallResult(InstallOutcome.notSupported);
    }
    if (!await apk.exists()) {
      return const InstallResult(InstallOutcome.failed, detail: 'the download is no longer there');
    }
    // Checked before offering rather than after failing: the installer would
    // otherwise open and immediately refuse, with nothing explaining why.
    if (!await isPermitted) {
      return const InstallResult(InstallOutcome.permissionRequired);
    }

    try {
      final ok = await channel.invokeMethod<bool>('install', {'path': apk.path}) ?? false;
      return ok
          ? const InstallResult(InstallOutcome.handedOff)
          : const InstallResult(InstallOutcome.failed, detail: 'the installer did not open');
    } on PlatformException catch (e) {
      return InstallResult(InstallOutcome.failed, detail: e.message);
    } catch (e) {
      return InstallResult(InstallOutcome.failed, detail: '$e');
    }
  }
}
