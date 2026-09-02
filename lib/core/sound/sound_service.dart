import 'dart:io';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sound_generator.dart';

class SoundService {
  static final AudioPlayer _player = AudioPlayer();
  static AlarmSoundPreset _currentPreset = AlarmSoundPreset.melodicChime;
  static String? _customSoundPath;
  static String? _customSoundName;
  static bool _useCustomSound = false;
  static bool _audioAlertsEnabled = false; // Default: OFF
  static bool _initialized = false;
  static final Map<AlarmSoundPreset, Uint8List> _audioCache = {};

  static AlarmSoundPreset get currentPreset => _currentPreset;
  static String? get customSoundPath => _customSoundPath;
  static String? get customSoundName => _customSoundName;
  static bool get useCustomSound => _useCustomSound;
  static bool get audioAlertsEnabled => _audioAlertsEnabled;

  static Future<void> init() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _audioAlertsEnabled = prefs.getBool('setting_audio_alerts_enabled') ?? false;

      final savedPreset = prefs.getString('setting_alarm_preset');
      if (savedPreset != null) {
        _currentPreset = AlarmSoundPreset.values.firstWhere(
          (e) => e.name == savedPreset,
          orElse: () => AlarmSoundPreset.melodicChime,
        );
      }

      _customSoundPath = prefs.getString('setting_custom_sound_path');
      _customSoundName = prefs.getString('setting_custom_sound_name');
      _useCustomSound = prefs.getBool('setting_use_custom_sound') ?? false;

      // Validate custom file existence
      if (_customSoundPath != null && !File(_customSoundPath!).existsSync()) {
        _customSoundPath = null;
        _customSoundName = null;
        _useCustomSound = false;
      }

      // Pre-warm synthesizer cache for zero latency
      for (final preset in AlarmSoundPreset.values) {
        _audioCache[preset] = SoundGenerator.createWav(preset);
      }
      _initialized = true;
    } catch (_) {}
  }

  static Future<void> setAudioAlertsEnabled(bool enabled) async {
    _audioAlertsEnabled = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('setting_audio_alerts_enabled', enabled);
    } catch (_) {}
  }

  static Future<void> selectPreset(AlarmSoundPreset preset) async {
    _currentPreset = preset;
    _useCustomSound = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('setting_alarm_preset', preset.name);
      await prefs.setBool('setting_use_custom_sound', false);
    } catch (_) {}
  }

  static Future<void> setCustomSound(String path, String displayName) async {
    _customSoundPath = path;
    _customSoundName = displayName;
    _useCustomSound = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('setting_custom_sound_path', path);
      await prefs.setString('setting_custom_sound_name', displayName);
      await prefs.setBool('setting_use_custom_sound', true);
    } catch (_) {}
  }

  static Future<void> clearCustomSound() async {
    try {
      if (_customSoundPath != null) {
        final file = File(_customSoundPath!);
        if (file.existsSync()) {
          await file.delete();
        }
      }
    } catch (_) {}

    _customSoundPath = null;
    _customSoundName = null;
    _useCustomSound = false;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('setting_custom_sound_path');
      await prefs.remove('setting_custom_sound_name');
      await prefs.setBool('setting_use_custom_sound', false);
    } catch (_) {}
  }

  static Future<void> playCompletionAlarm() async {
    if (!_audioAlertsEnabled) return;
    if (_useCustomSound && _customSoundPath != null && File(_customSoundPath!).existsSync()) {
      await playCustomSound();
    } else {
      await playPreset(_currentPreset);
    }
  }

  static Future<void> playAlarm() async => playCompletionAlarm();

  static Future<void> playCustomSound([String? explicitPath]) async {
    final targetPath = explicitPath ?? _customSoundPath;
    if (targetPath == null) return;
    try {
      await _player.stop();
      await _player.play(DeviceFileSource(targetPath));
      await HapticFeedback.heavyImpact();
    } catch (_) {
      try {
        await HapticFeedback.heavyImpact();
      } catch (_) {}
    }
  }

  static Future<void> playPreset(AlarmSoundPreset preset) async {
    try {
      final wavBytes = _audioCache[preset] ?? SoundGenerator.createWav(preset);
      _audioCache[preset] = wavBytes;

      await _player.stop();
      await _player.play(BytesSource(wavBytes));
      await HapticFeedback.heavyImpact();
    } catch (_) {
      try {
        await HapticFeedback.heavyImpact();
      } catch (_) {}
    }
  }

  static Future<void> playTick() async {
    try {
      await HapticFeedback.selectionClick();
    } catch (_) {}
  }

  static Future<void> playAlertSound() async {
    await playCompletionAlarm();
  }
}
