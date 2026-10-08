import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/chastity_timer.dart';

/// A timer setup saved under a name, to start the next one from.
///
/// It holds the setup screen's settings as they were - every switch and
/// value, so loading it puts the screen back exactly. Never the lock's
/// combination digits (a saved copy of a lock's code is not something to
/// keep), and never who the timer is for.
class TimerPreset {
  const TimerPreset({required this.id, required this.name, required this.role, required this.settings, required this.savedAt});

  final String id;
  final String name;

  /// The setup it is for: a player's own timer, or a director's.
  final TimerRole role;
  final Map<String, dynamic> settings;
  final DateTime savedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'role': role.name,
        'settings': settings,
        'savedAt': savedAt.toIso8601String(),
      };

  factory TimerPreset.fromJson(Map<String, dynamic> j) => TimerPreset(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Saved settings',
        role: j['role'] == 'director' ? TimerRole.director : TimerRole.player,
        settings: Map<String, dynamic>.from(j['settings'] as Map),
        savedAt: DateTime.tryParse(j['savedAt'] as String? ?? '') ?? DateTime.now(),
      );
}

/// The saved setups on this device.
class TimerPresets {
  TimerPresets._();

  static const String prefsKey = 'chastity_timer_presets_v1';

  /// Settings that must never be kept, whatever the screen hands over.
  static const _neverKept = {'comboDigits', 'combination', 'partnerCode', 'partnerName'};

  static Future<List<TimerPreset>> all({TimerRole? role}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw == null) return [];
      final list = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((m) => TimerPreset.fromJson(Map<String, dynamic>.from(m)))
          .where((p) => role == null || p.role == role)
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return list;
    } catch (_) {
      return [];
    }
  }

  /// Saves [settings] as [name] for [role]. The same name for the same role
  /// replaces the earlier one.
  static Future<TimerPreset> save(String name, TimerRole role, Map<String, dynamic> settings) async {
    final clean = Map<String, dynamic>.from(settings)..removeWhere((k, _) => _neverKept.contains(k));
    final everything = await all();
    final existing = everything.where((p) => p.role == role && p.name.toLowerCase() == name.trim().toLowerCase()).firstOrNull;
    final preset = TimerPreset(
      id: existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim(),
      role: role,
      settings: clean,
      savedAt: DateTime.now(),
    );
    await _write([...everything.where((p) => p.id != preset.id), preset]);
    return preset;
  }

  static Future<void> delete(String id) async => _write((await all()).where((p) => p.id != id).toList());

  static Future<void> _write(List<TimerPreset> presets) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, jsonEncode(presets.map((p) => p.toJson()).toList()));
  }
}
