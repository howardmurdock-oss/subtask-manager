import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/models/cadence_config.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/core/sound/cadence_sound_generator.dart';
import 'package:orders_app/services/cadence_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CadenceConfig Model & Curve Math Tests', () {
    test('Fixed BPM mode always returns exact fixed BPM', () {
      final config = CadenceConfig.fixed(bpm: 75);
      expect(config.mode, CadenceMode.fixed);
      expect(config.bpm, 75);

      // At start, middle, and end, fixed BPM remains 75
      expect(config.calculateBpmAt(0, 60), 75);
      expect(config.calculateBpmAt(30, 60), 75);
      expect(config.calculateBpmAt(60, 60), 75);
      expect(config.calculateTrendAt(30, 60), TempoTrend.steady);
    });

    test('Wave mode starts at minBpm, peaks at maxBpm, and returns to minBpm smoothly', () {
      // 1 wave cycle over 60 seconds
      final config = CadenceConfig.wave(minBpm: 30, maxBpm: 90, waveCount: 1);

      // t = 0: Start of wave -> exactly minBpm
      expect(config.calculateBpmAt(0, 60), 30);

      // t = 30: Peak of wave (midpoint) -> exactly maxBpm
      expect(config.calculateBpmAt(30, 60), 90);

      // t = 60: End of wave -> returns to minBpm
      expect(config.calculateBpmAt(60, 60), 30);

      // Check trend: accelerating from 0 to 15s, decelerating from 30 to 45s
      expect(config.calculateTrendAt(10, 60), TempoTrend.accelerating);
      expect(config.calculateTrendAt(45, 60), TempoTrend.decelerating);
    });

    test('Peak (Pyramid) mode ramps up to midpoint and cools down to end', () {
      final config = CadenceConfig.peak(minBpm: 40, maxBpm: 100);

      // t = 0 (progress 0%): minBpm
      expect(config.calculateBpmAt(0, 100), 40);

      // t = 25 (progress 25%): halfway up to peak -> 70
      expect(config.calculateBpmAt(25, 100), 70);

      // t = 50 (progress 50%): peak -> 100
      expect(config.calculateBpmAt(50, 100), 100);

      // t = 75 (progress 75%): halfway down -> 70
      expect(config.calculateBpmAt(75, 100), 70);

      // t = 100 (progress 100%): back to min -> 40
      expect(config.calculateBpmAt(100, 100), 40);

      // Trend check
      expect(config.calculateTrendAt(20, 100), TempoTrend.accelerating);
      expect(config.calculateTrendAt(70, 100), TempoTrend.decelerating);
    });

    test('Ramp (Accelerando) mode progressively accelerates from start to finish', () {
      final config = CadenceConfig.ramp(minBpm: 30, maxBpm: 120);

      // t = 0: minBpm
      expect(config.calculateBpmAt(0, 90), 30);

      // t = 45 (50% progress): midpoint -> 75
      expect(config.calculateBpmAt(45, 90), 75);

      // t = 90 (100% progress): maxBpm -> 120
      expect(config.calculateBpmAt(90, 90), 120);

      // Trend is consistently accelerating throughout
      expect(config.calculateTrendAt(10, 90), TempoTrend.accelerating);
      expect(config.calculateTrendAt(50, 90), TempoTrend.accelerating);
    });

    test('Random mode stays bounded between minBpm and maxBpm', () {
      final config = CadenceConfig.random(minBpm: 35, maxBpm: 105, intervalSeconds: 10);

      for (double t = 0; t <= 120; t += 5) {
        final bpm = config.calculateBpmAt(t, 120);
        expect(bpm, greaterThanOrEqualTo(35));
        expect(bpm, lessThanOrEqualTo(105));
      }
    });

    test('JSON serialization and deserialization roundtrip preserves all parameters', () {
      const original = CadenceConfig(
        mode: CadenceMode.wave,
        bpm: 80,
        minBpm: 25,
        maxBpm: 140,
        waveCount: 3,
        randomIntervalSeconds: 20,
        soundTone: CadenceSoundTone.bell,
        enableAudio: false,
        enableHaptics: true,
        enableVisual: false,
      );

      final json = original.toJson();
      final restored = CadenceConfig.fromJson(json);

      expect(restored.mode, CadenceMode.wave);
      expect(restored.bpm, 80);
      expect(restored.minBpm, 25);
      expect(restored.maxBpm, 140);
      expect(restored.waveCount, 3);
      expect(restored.randomIntervalSeconds, 20);
      expect(restored.soundTone, CadenceSoundTone.bell);
      expect(restored.enableAudio, isFalse);
      expect(restored.enableHaptics, isTrue);
      expect(restored.enableVisual, isFalse);
    });

    test('OrderItem correctly serializes and deserializes attached CadenceConfig', () {
      final cadence = CadenceConfig.ramp(minBpm: 40, maxBpm: 130);
      final order = OrderItem(
        title: 'Endurance Wall Sit',
        description: 'Paced breathing and stance.',
        durationType: DurationType.actionTimer,
        actionDurationSeconds: 90,
        cadenceConfig: cadence,
      );

      final json = order.toJson();
      expect(json['cadenceConfig'], isNotNull);

      final restored = OrderItem.fromJson(json);
      expect(restored.cadenceConfig, isNotNull);
      expect(restored.cadenceConfig!.mode, CadenceMode.ramp);
      expect(restored.cadenceConfig!.minBpm, 40);
      expect(restored.cadenceConfig!.maxBpm, 130);
    });
  });

  group('CadenceSoundGenerator Synthesizer Tests', () {
    test('Synthesizes valid PCM WAV headers and non-empty byte arrays for all tones', () {
      for (final tone in CadenceSoundTone.values) {
        final wav = CadenceSoundGenerator.getWav(tone);
        expect(wav, isNotEmpty);
        expect(wav.length, greaterThan(44)); // Must have at least 44-byte RIFF header

        // All tone buffers must be >=4000 bytes (>=45ms at 44.1kHz 16-bit mono)
        // to prevent hardware buffer underruns on Android AudioTrack / NuPlayer
        expect(wav.length, greaterThanOrEqualTo(4000));

        // RIFF header magic
        expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
        expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
        expect(String.fromCharCodes(wav.sublist(12, 16)), 'fmt ');
        expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');
      }

      // Tick specifically must have 55ms duration (4894 bytes)
      final tickWav = CadenceSoundGenerator.getWav(CadenceSoundTone.tick);
      expect(tickWav.length, greaterThanOrEqualTo(4800));

      final shiftCue = CadenceSoundGenerator.getShiftCueWav();
      expect(shiftCue, isNotEmpty);
      expect(shiftCue.length, greaterThanOrEqualTo(4000));
      expect(String.fromCharCodes(shiftCue.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(shiftCue.sublist(8, 12)), 'WAVE');
    });
  });

  group('CadenceEngine Lifecycle & Execution Tests', () {
    test('Initializes in stopped state with expected starting BPM and progress', () {
      final engine = CadenceEngine(
        config: CadenceConfig.peak(minBpm: 40, maxBpm: 100),
        totalDurationSeconds: 60,
      );

      expect(engine.isRunning, isFalse);
      expect(engine.isPaused, isFalse);
      expect(engine.beatCount, 0);
      expect(engine.currentBpm, 40);
      expect(engine.progress, 0.0);
    });

    testWidgets('Start fires immediate first beat and updates state cleanly', (tester) async {
      final engine = CadenceEngine(
        config: CadenceConfig.fixed(bpm: 120).copyWith(enableAudio: false, enableHaptics: false),
        totalDurationSeconds: 10,
      );

      CadenceTick? firstTick;
      engine.onTickCallback = (tick) {
        firstTick = tick;
      };

      engine.start();

      expect(engine.isRunning, isTrue);
      expect(engine.beatCount, 1);
      expect(firstTick, isNotNull);
      expect(firstTick!.beatNumber, 1);
      expect(firstTick!.currentBpm, 120);

      engine.pause();
      expect(engine.isPaused, isTrue);

      engine.resume();
      expect(engine.isPaused, isFalse);

      engine.stop();
      expect(engine.isRunning, isFalse);

      engine.reset();
      expect(engine.beatCount, 0);
      expect(engine.elapsedSeconds, 0.0);

      engine.dispose();
    });

    test('CadenceMode displayName provides clean mode names without brackets', () {
      expect(CadenceMode.fixed.displayName, 'Fixed BPM');
      expect(CadenceMode.wave.displayName, 'Wave');
      expect(CadenceMode.peak.displayName, 'Peak');
      expect(CadenceMode.ramp.displayName, 'Ramp');
      expect(CadenceMode.random.displayName, 'Random');
      expect(CadenceMode.none.displayName, 'None');
    });

    test('CadenceConfig equality and hashCode work correctly', () {
      const cfgA = CadenceConfig(mode: CadenceMode.wave, minBpm: 40, maxBpm: 100);
      const cfgB = CadenceConfig(mode: CadenceMode.wave, minBpm: 40, maxBpm: 100);
      const cfgC = CadenceConfig(mode: CadenceMode.wave, minBpm: 50, maxBpm: 100);

      expect(cfgA, equals(cfgB));
      expect(cfgA.hashCode, equals(cfgB.hashCode));
      expect(cfgA, isNot(equals(cfgC)));
    });

    test('OrderItem and OrderPack preserve cadenceConfig across copyWith and serialization', () {
      final orderWithCadence = OrderItem(
        title: 'Paced Breathing Routine',
        description: 'Breathe to the wave metronome',
        durationType: DurationType.actionTimer,
        actionDurationSeconds: 180,
        cadenceConfig: const CadenceConfig(
          mode: CadenceMode.wave,
          minBpm: 20,
          maxBpm: 60,
          waveCount: 3,
        ),
      );

      final json = orderWithCadence.toJson();
      final roundtrip = OrderItem.fromJson(json);

      expect(roundtrip.cadenceConfig, isNotNull);
      expect(roundtrip.cadenceConfig!.mode, CadenceMode.wave);
      expect(roundtrip.cadenceConfig!.minBpm, 20);
      expect(roundtrip.cadenceConfig!.maxBpm, 60);
      expect(roundtrip.cadenceConfig!.waveCount, 3);
      expect(roundtrip.cadenceConfig, equals(orderWithCadence.cadenceConfig));
    });
  });
}
