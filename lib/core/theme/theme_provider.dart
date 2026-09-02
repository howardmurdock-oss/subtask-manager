import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_theme.dart';

class ThemeProvider extends ChangeNotifier {
  static const String _prefThemeKey = 'selected_theme_preset';
  static const String _prefAccentKey = 'custom_accent_color';

  AppThemePreset _currentPreset = AppThemePreset.obsidianCyberpunk;
  Color? _customAccent;

  AppThemePreset get currentPreset => _currentPreset;
  Color? get customAccent => _customAccent;

  AppThemeConfig get currentConfig {
    final base = AppThemes.getByPreset(_currentPreset);
    if (_customAccent == null) return base;
    return AppThemeConfig(
      preset: base.preset,
      displayName: base.displayName,
      primary: _customAccent!,
      secondary: base.secondary,
      background: base.background,
      surface: base.surface,
      surfaceLight: base.surfaceLight,
      textPrimary: base.textPrimary,
      textSecondary: base.textSecondary,
      accentSuccess: base.accentSuccess,
      accentWarning: base.accentWarning,
      accentDanger: base.accentDanger,
      isDark: base.isDark,
    );
  }

  ThemeData get themeData => currentConfig.toThemeData();

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPresetName = prefs.getString(_prefThemeKey);
    if (savedPresetName != null) {
      _currentPreset = AppThemePreset.values.firstWhere(
        (e) => e.name == savedPresetName,
        orElse: () => AppThemePreset.obsidianCyberpunk,
      );
    }
    final savedAccent = prefs.getInt(_prefAccentKey);
    if (savedAccent != null) {
      _customAccent = Color(savedAccent);
    }
    notifyListeners();
  }

  Future<void> setPreset(AppThemePreset preset) async {
    _currentPreset = preset;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefThemeKey, preset.name);
  }

  Future<void> setCustomAccent(Color? color) async {
    _customAccent = color;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (color != null) {
      await prefs.setInt(_prefAccentKey, color.value);
    } else {
      await prefs.remove(_prefAccentKey);
    }
  }
}
