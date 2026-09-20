import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Options that belong in the debug panel rather than in ordinary settings.
///
/// Kept apart from the app's real settings on purpose: these change what the
/// app lets you do to your own record - clearing a directive without
/// completing or forfeiting it - so they are off unless someone has gone
/// looking for them.
class DebugSettings extends ChangeNotifier {
  DebugSettings._();

  static final DebugSettings instance = DebugSettings._();

  static const String showPlayerOverridesKey = 'debug_show_player_overrides_v1';

  bool _showPlayerOverrides = false;

  /// Whether the player dashboard offers the dismiss and clean-up controls.
  /// Off by default: a directive is normally finished or forfeited, and both
  /// of those tell the director something. Clearing one quietly does not.
  bool get showPlayerOverrides => _showPlayerOverrides;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      _showPlayerOverrides = prefs.getBool(showPlayerOverridesKey) ?? false;
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
