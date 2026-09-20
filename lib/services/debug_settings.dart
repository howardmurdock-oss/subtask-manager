import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Options that belong in the debug panel rather than in ordinary settings.
///
/// Kept apart from the app's real settings on purpose: these change what the
/// app lets you do to your own record, so they are off unless someone has gone
/// looking for them.
class DebugSettings extends ChangeNotifier {
  DebugSettings._();

  static final DebugSettings instance = DebugSettings._();

  static const String showPlayerOverridesKey = 'debug_show_player_overrides_v1';
  static const String updateManifestUrlKey = 'debug_update_manifest_url_v1';

  /// A staging manifest, published alongside the real one. Pointing a device
  /// at it exercises the whole update path - fetch, compare, prompt - without
  /// telling every other user that a version exists which does not.
  static const String testManifestUrl = 'https://subtaskmanager.com/latest-test.json';

  bool _showPlayerOverrides = false;
  String? _updateManifestUrl;

  /// Whether the player dashboard offers the dismiss and clean-up controls.
  ///
  /// Off by default. An emergency clear does notify the director, but unlike a
  /// forfeit it costs no tokens and leaves no entry on the discipline log - so
  /// it is a way around the record rather than a normal way to end a directive.
  bool get showPlayerOverrides => _showPlayerOverrides;

  /// Where update checks look, when it is not the published manifest.
  String? get updateManifestUrl => _updateManifestUrl;

  Future<void> setUpdateManifestUrl(String? url) async {
    _updateManifestUrl = (url == null || url.isEmpty) ? null : url;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_updateManifestUrl == null) {
        await prefs.remove(updateManifestUrlKey);
      } else {
        await prefs.setString(updateManifestUrlKey, _updateManifestUrl!);
      }
      // So the next check happens now rather than up to a day later.
      await prefs.remove('update_last_checked_v1');
      await prefs.remove('update_skipped_version_v1');
    } catch (_) {}
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      _showPlayerOverrides = prefs.getBool(showPlayerOverridesKey) ?? false;
      _updateManifestUrl = prefs.getString(updateManifestUrlKey);
      notifyListeners();
    } catch (_) {
      // Defaults stand.
    }
  }

  Future<void> setShowPlayerOverrides(bool value) async {
    if (_showPlayerOverrides == value) return;
    _showPlayerOverrides = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(showPlayerOverridesKey, value);
    } catch (_) {}
  }
}
