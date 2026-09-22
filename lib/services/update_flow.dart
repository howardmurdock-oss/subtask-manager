import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'update_downloader.dart';
import 'update_installer.dart';
import 'update_service.dart';

enum UpdatePhase {
  /// An update exists and nothing has been started.
  offered,
  downloading,
  readyToInstall,

  /// Handed to the system installer; the user is deciding.
  installing,

  /// The app may not request installs yet.
  permissionRequired,
  failed,

  /// Waved away for this version, or dismissed for now.
  dismissed,
}

/// Downloading and installing an update, as one piece of state.
///
/// Shared rather than per-screen: the banner and the settings card are two
/// views of the same thing, and two of them each holding their own would mean
/// two downloads of the same 65MB file, and a progress bar in one place that
/// knows nothing about a cancellation in the other.
class UpdateFlow extends ChangeNotifier {
  UpdateFlow._();

  static final UpdateFlow instance = UpdateFlow._();

  /// Where downloads land. Overridden in tests, and the seam Windows will use
  /// when it needs somewhere beside the installation rather than a cache.
  @visibleForTesting
  static Future<Directory> Function() downloadDirectory = _temporaryUpdatesDirectory;

  /// The app's own cache, which is also the only directory the Android
  /// FileProvider is willing to share.
  static Future<Directory> _temporaryUpdatesDirectory() async => Directory(
      '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}updates');

  AppUpdate? _update;
  UpdatePhase _phase = UpdatePhase.dismissed;
  double? _progress;
  String? _message;
  File? _downloaded;
  DownloadCancellation? _cancellation;

  AppUpdate? get update => _update;
  UpdatePhase get phase => _phase;

  /// 0..1 where the size is known, null while it is not.
  double? get progress => _progress;
  String? get message => _message;

  bool get isBusy => _phase == UpdatePhase.downloading || _phase == UpdatePhase.installing;

  /// Whether this build can install the update itself, rather than sending the
  /// user to a browser. Needs a platform that can install, and a manifest that
  /// was signed - an unsigned one names a file nobody vouched for.
  bool get canInstallInApp {
    final u = _update;
    return u != null &&
        UpdateInstaller.isSupported &&
        u.manifestVerified &&
        u.downloadUrl != null &&
        u.sha256 != null;
  }

  void offer(AppUpdate update) {
    if (_update?.version == update.version && isBusy) return;
    _update = update;
    _phase = UpdatePhase.offered;
    _progress = null;
    _message = null;
    _downloaded = null;
    notifyListeners();
  }

  /// Hides the prompt until the next launch, leaving the version alone.
  void dismiss() {
    _cancellation?.cancel();
    _phase = UpdatePhase.dismissed;
    notifyListeners();
  }

  /// Hides this version for good - it stays skipped until a newer one is
  /// published, rather than for a while.
  Future<void> skip() async {
    final version = _update?.version;
    _cancellation?.cancel();
    _phase = UpdatePhase.dismissed;
    notifyListeners();
    if (version != null) await UpdateService.skip(version);
  }

  /// Abandons a download in progress. The partial file is deleted by the
  /// downloader; the update stays on offer.
  void cancelDownload() {
    _cancellation?.cancel();
    _cancellation = null;
    _phase = UpdatePhase.offered;
    _progress = null;
    _message = 'Download cancelled.';
    notifyListeners();
  }

  Future<void> downloadAndInstall() async {
    final update = _update;
    if (update == null || isBusy) return;

    final cancellation = DownloadCancellation();
    _cancellation = cancellation;
    _phase = UpdatePhase.downloading;
    _progress = 0;
    _message = null;
    notifyListeners();

    final result = await UpdateDownloader.download(
      update: update,
      into: await downloadDirectory(),
      cancellation: cancellation,
      onProgress: (received, total) {
        if (_phase != UpdatePhase.downloading) return;
        _progress = (total != null && total > 0) ? received / total : null;
        notifyListeners();
      },
    );
    _cancellation = null;

    switch (result.outcome) {
      case UpdateDownloadOutcome.ready:
        _downloaded = result.file;
        _phase = UpdatePhase.readyToInstall;
        _progress = 1;
        notifyListeners();
        await install();
        return;
      case UpdateDownloadOutcome.cancelled:
        // cancelDownload has already set the state the user asked for.
        return;
      case UpdateDownloadOutcome.digestMismatch:
        _fail('That download did not match the published release, so it was discarded.');
        return;
      case UpdateDownloadOutcome.unverifiedManifest:
        _fail('This release could not be verified as genuine, so it was not downloaded.');
        return;
      case UpdateDownloadOutcome.notOffered:
        _fail('There is no verified download for this device.');
        return;
      case UpdateDownloadOutcome.failed:
        _fail('The download did not finish. ${result.detail ?? ''}'.trim());
        return;
    }
  }

  Future<void> install() async {
    final file = _downloaded;
    if (file == null) return;

    _phase = UpdatePhase.installing;
    notifyListeners();

    final result = await UpdateInstaller.install(file);
    switch (result.outcome) {
      case InstallOutcome.handedOff:
        _message = 'Follow the prompt to finish installing.';
        notifyListeners();
      case InstallOutcome.permissionRequired:
        _phase = UpdatePhase.permissionRequired;
        _message = 'Android needs permission to install updates from this app.';
        notifyListeners();
      case InstallOutcome.notSupported:
        _fail('This device cannot install updates from inside the app.');
      case InstallOutcome.failed:
        _fail(result.detail ?? 'The installer could not be opened.');
    }
  }

  Future<void> grantInstallPermission() async {
    await UpdateInstaller.openPermissionSettings();
    // Back to ready: the file is still downloaded, so the user can try again
    // without fetching it a second time.
    if (_downloaded != null) {
      _phase = UpdatePhase.readyToInstall;
      _message = 'Once allowed, tap Install again.';
      notifyListeners();
    }
  }

  void _fail(String reason) {
    _phase = UpdatePhase.failed;
    _progress = null;
    _message = reason;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _update = null;
    _phase = UpdatePhase.dismissed;
    _progress = null;
    _message = null;
    _downloaded = null;
    _cancellation = null;
  }
}
