import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/core/sound/sound_generator.dart';
import 'package:orders_app/core/sound/sound_service.dart';

void main() {
  group('SoundGenerator Audio Synthesis Tests', () {
    test('generateMelodicChime produces valid WAV byte container', () {
      final wavBytes = SoundGenerator.createWav(AlarmSoundPreset.melodicChime);
      expect(wavBytes.length, greaterThan(1000));

      // Validate RIFF header
      expect(String.fromCharCodes(wavBytes.sublist(0, 4)), equals('RIFF'));
      // Validate WAVE tag
      expect(String.fromCharCodes(wavBytes.sublist(8, 12)), equals('WAVE'));
      // Validate fmt chunk
      expect(String.fromCharCodes(wavBytes.sublist(12, 16)), equals('fmt '));
    });

    test('All sound presets generate valid non-empty audio bytes', () {
      for (final preset in AlarmSoundPreset.values) {
        final bytes = SoundGenerator.createWav(preset);
        expect(bytes.isNotEmpty, isTrue);
        expect(String.fromCharCodes(bytes.sublist(0, 4)), equals('RIFF'));
        expect(String.fromCharCodes(bytes.sublist(8, 12)), equals('WAVE'));
      }
    });

    test('SoundService audioAlertsEnabled defaults to off (false)', () {
      expect(SoundService.audioAlertsEnabled, isFalse);
    });
  });
}
