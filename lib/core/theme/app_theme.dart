import 'package:flutter/material.dart';

enum AppThemePreset {
  obsidianCyberpunk,
  minimalistNoir,
  velvetCrimson,
  slateTerminal,
  discreetLight,
}

class AppThemeConfig {
  final AppThemePreset preset;
  final String displayName;
  final Color primary;
  final Color secondary;
  final Color background;
  final Color surface;
  final Color surfaceLight;
  final Color textPrimary;
  final Color textSecondary;
  final Color accentSuccess;
  final Color accentWarning;
  final Color accentDanger;
  final bool isDark;

  const AppThemeConfig({
    required this.preset,
    required this.displayName,
    required this.primary,
    required this.secondary,
    required this.background,
    required this.surface,
    required this.surfaceLight,
    required this.textPrimary,
    required this.textSecondary,
    required this.accentSuccess,
    required this.accentWarning,
    required this.accentDanger,
    this.isDark = true,
  });

  ThemeData toThemeData() {
    return ThemeData(
      useMaterial3: true,
      brightness: isDark ? Brightness.dark : Brightness.light,
      primaryColor: primary,
      scaffoldBackgroundColor: background,
      colorScheme: ColorScheme(
        brightness: isDark ? Brightness.dark : Brightness.light,
        primary: primary,
        onPrimary: isDark ? Colors.black : Colors.white,
        secondary: secondary,
        onSecondary: Colors.white,
        error: accentDanger,
        onError: Colors.white,
        surface: surface,
        onSurface: textPrimary,
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: surfaceLight.withOpacity(0.4),
            width: 1,
          ),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        elevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: textPrimary),
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: surfaceLight, width: 1),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceLight.withOpacity(0.3),
        floatingLabelBehavior: FloatingLabelBehavior.never,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: surfaceLight.withOpacity(0.5)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: surfaceLight.withOpacity(0.5)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: primary, width: 1.5),
        ),
        labelStyle: TextStyle(color: textSecondary),
        hintStyle: TextStyle(color: textSecondary.withOpacity(0.5)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: isDark ? Colors.black : Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}

class AppThemes {
  static const obsidianCyberpunk = AppThemeConfig(
    preset: AppThemePreset.obsidianCyberpunk,
    displayName: 'Obsidian Cyberpunk',
    primary: Color(0xFF00F0FF), // Electric Cyan
    secondary: Color(0xFFBD00FF), // Neon Purple
    background: Color(0xFF0D0E15),
    surface: Color(0xFF161926),
    surfaceLight: Color(0xFF262C40),
    textPrimary: Color(0xFFF1F5F9),
    textSecondary: Color(0xFF94A3B8),
    accentSuccess: Color(0xFF00FF9D),
    accentWarning: Color(0xFFFFB800),
    accentDanger: Color(0xFFFF2A6D),
    isDark: true,
  );

  static const minimalistNoir = AppThemeConfig(
    preset: AppThemePreset.minimalistNoir,
    displayName: 'Minimalist Noir',
    primary: Color(0xFFFFFFFF),
    secondary: Color(0xFFA1A1AA),
    background: Color(0xFF09090B),
    surface: Color(0xFF18181B),
    surfaceLight: Color(0xFF27272A),
    textPrimary: Color(0xFFFAFAFA),
    textSecondary: Color(0xFFA1A1AA),
    accentSuccess: Color(0xFF22C55E),
    accentWarning: Color(0xFFEAB308),
    accentDanger: Color(0xFFEF4444),
    isDark: true,
  );

  static const velvetCrimson = AppThemeConfig(
    preset: AppThemePreset.velvetCrimson,
    displayName: 'Velvet Crimson',
    primary: Color(0xFFE11D48), // Rose Crimson
    secondary: Color(0xFFFB7185),
    background: Color(0xFF14080E),
    surface: Color(0xFF220F18),
    surfaceLight: Color(0xFF381A27),
    textPrimary: Color(0xFFFFF1F2),
    textSecondary: Color(0xFFFDA4AF),
    accentSuccess: Color(0xFF10B981),
    accentWarning: Color(0xFFF59E0B),
    accentDanger: Color(0xFFBE123C),
    isDark: true,
  );

  static const slateTerminal = AppThemeConfig(
    preset: AppThemePreset.slateTerminal,
    displayName: 'Slate Terminal',
    primary: Color(0xFF38BDF8), // Sky Blue
    secondary: Color(0xFF34D399), // Emerald
    background: Color(0xFF0F172A),
    surface: Color(0xFF1E293B),
    surfaceLight: Color(0xFF334155),
    textPrimary: Color(0xFFF8FAFC),
    textSecondary: Color(0xFF94A3B8),
    accentSuccess: Color(0xFF10B981),
    accentWarning: Color(0xFFFBBF24),
    accentDanger: Color(0xFFF87171),
    isDark: true,
  );

  static const discreetLight = AppThemeConfig(
    preset: AppThemePreset.discreetLight,
    displayName: 'Discreet Clean',
    primary: Color(0xFF2563EB),
    secondary: Color(0xFF475569),
    background: Color(0xFFF8FAFC),
    surface: Color(0xFFFFFFFF),
    surfaceLight: Color(0xFFE2E8F0),
    textPrimary: Color(0xFF0F172A),
    textSecondary: Color(0xFF64748B),
    accentSuccess: Color(0xFF16A34A),
    accentWarning: Color(0xFFD97706),
    accentDanger: Color(0xFFDC2626),
    isDark: false,
  );

  static final List<AppThemeConfig> all = [
    obsidianCyberpunk,
    minimalistNoir,
    velvetCrimson,
    slateTerminal,
    discreetLight,
  ];

  static AppThemeConfig getByPreset(AppThemePreset preset) {
    return all.firstWhere(
      (e) => e.preset == preset,
      orElse: () => obsidianCyberpunk,
    );
  }
}
