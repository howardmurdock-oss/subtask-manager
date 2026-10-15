import 'dart:math';
import 'dart:typed_data';
import '../../models/cadence_config.dart';

/// Synthesizes acoustic PCM WAV audio samples in memory for metronome clicks and cues.
class CadenceSoundGenerator {
  static const int sampleRate = 44100;

  static final Map<CadenceSoundTone, Uint8List> _cache = {};
  static Uint8List? _shiftCueCache;

  /// Retrieves or synthesizes the WAV audio bytes for [tone].
  static Uint8List getWav(CadenceSoundTone tone) {
    return _cache.putIfAbsent(tone, () => _generateTone(tone));
  }

  /// Retrieves or synthesizes the WAV audio bytes for the tempo shift cue blip.
  static Uint8List getShiftCueWav() {
    return _shiftCueCache ??= _generateShiftCue();
  }

  static Uint8List _generateTone(CadenceSoundTone tone) {
    switch (tone) {
      case CadenceSoundTone.woodblock:
        return _generateWoodblock();
      case CadenceSoundTone.tick:
        return _generateTick();
      case CadenceSoundTone.beep:
        return _generateBeep();
      case CadenceSoundTone.bass:
        return _generateBass();
      case CadenceSoundTone.bell:
        return _generateBell();
    }
  }

  /// Clean, woody percussion tap (920Hz + harmonic, 50ms)
  static Uint8List _generateWoodblock() {
    const duration = 0.050;
    final numSamples = (sampleRate * duration).toInt();
    final samples = Float64List(numSamples);

    for (int i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      final attack = (t < 0.002) ? (t / 0.002) : 1.0;
      final envelope = attack * exp(-120.0 * t);
      final wave = 0.70 * sin(2 * pi * 920.0 * t) + 0.30 * sin(2 * pi * 1840.0 * t);
      final fadeOut = (t > 0.045) ? 0.5 * (1.0 + cos(pi * (t - 0.045) / 0.005)) : 1.0;
      samples[i] = wave * envelope * fadeOut * 0.90;
    }
    return _samplesToWavBytes(samples, sampleRate);
  }

  /// Crisp, authentic mechanical metronome click (dual-stage: escapement strike + wooden case resonance, 55ms)
  static Uint8List _generateTick() {
    const duration = 0.055;
    final numSamples = (sampleRate * duration).toInt();
    final samples = Float64List(numSamples);

    for (int i = 0; i < numSamples; i++) {
      final t = i / sampleRate;

      // 1. Sharp mechanical escapement strike (high-frequency transient snap)
      final attackSnap = (t < 0.0006) ? (t / 0.0006) : 1.0;
      final envSnap = attackSnap * exp(-180.0 * t);
      final snapWave = 0.65 * sin(2 * pi * 2400.0 * t) + 0.35 * sin(2 * pi * 3800.0 * t);

      // 2. Resonant hollow wooden metronome casing (body resonance)
      final attackBody = (t < 0.0015) ? (t / 0.0015) : 1.0;
      final envBody = attackBody * exp(-95.0 * t);
      final bodyWave = 0.60 * sin(2 * pi * 880.0 * t) +
          0.30 * sin(2 * pi * 1320.0 * t) +
          0.10 * sin(2 * pi * 440.0 * t);

      // Smooth cosine fade out on the last 5ms to guarantee zero DC offset or pop
      final fadeOut = (t > 0.050) ? 0.5 * (1.0 + cos(pi * (t - 0.050) / 0.005)) : 1.0;

      samples[i] = (snapWave * envSnap * 0.55 + bodyWave * envBody * 0.45) * fadeOut * 0.95;
    }
    return _samplesToWavBytes(samples, sampleRate);
  }

  /// Minimalist acoustic sine ding (880Hz A5, 50ms)
  static Uint8List _generateBeep() {
    const duration = 0.050;
    final numSamples = (sampleRate * duration).toInt();
    final samples = Float64List(numSamples);

    for (int i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      final attack = (t < 0.003) ? (t / 0.003) : 1.0;
      final envelope = attack * exp(-70.0 * t);
      final wave = sin(2 * pi * 880.0 * t);
      final fadeOut = (t > 0.045) ? 0.5 * (1.0 + cos(pi * (t - 0.045) / 0.005)) : 1.0;
      samples[i] = wave * envelope * fadeOut * 0.85;
    }
    return _samplesToWavBytes(samples, sampleRate);
  }

  /// Deep, physical chest-pulse tone (95Hz, 60ms)
  static Uint8List _generateBass() {
    const duration = 0.060;
    final numSamples = (sampleRate * duration).toInt();
    final samples = Float64List(numSamples);

    for (int i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      final attack = (t < 0.006) ? (t / 0.006) : 1.0;
      final envelope = attack * exp(-55.0 * t);
      final wave = sin(2 * pi * 95.0 * t) + 0.35 * sin(2 * pi * 190.0 * t);
      final fadeOut = (t > 0.055) ? 0.5 * (1.0 + cos(pi * (t - 0.055) / 0.005)) : 1.0;
      samples[i] = wave * envelope * fadeOut * 0.95;
    }
    return _samplesToWavBytes(samples, sampleRate);
  }

  /// Crystal bell ting (1560Hz chime, 65ms)
  static Uint8List _generateBell() {
    const duration = 0.065;
    final numSamples = (sampleRate * duration).toInt();
    final samples = Float64List(numSamples);

    for (int i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      final attack = (t < 0.002) ? (t / 0.002) : 1.0;
      final envelope = attack * exp(-45.0 * t);
      final wave = 0.70 * sin(2 * pi * 1560.0 * t) + 0.30 * sin(2 * pi * 3120.0 * t);
      final fadeOut = (t > 0.060) ? 0.5 * (1.0 + cos(pi * (t - 0.060) / 0.005)) : 1.0;
      samples[i] = wave * envelope * fadeOut * 0.80;
    }
    return _samplesToWavBytes(samples, sampleRate);
  }

  /// Two-stage chirped blip indicating random tempo shift (55ms)
  static Uint8List _generateShiftCue() {
    const duration = 0.055;
    final numSamples = (sampleRate * duration).toInt();
    final samples = Float64List(numSamples);

    for (int i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      final freq = t < 0.027 ? 1200.0 : 1800.0;
      final envelope = exp(-45.0 * (t % 0.027));
      final wave = sin(2 * pi * freq * t);
      final fadeOut = (t > 0.050) ? 0.5 * (1.0 + cos(pi * (t - 0.050) / 0.005)) : 1.0;
      samples[i] = wave * envelope * fadeOut * 0.85;
    }
    return _samplesToWavBytes(samples, sampleRate);
  }

  /// Packs normalized Float64 audio samples into a standard 16-bit PCM WAV container
  static Uint8List _samplesToWavBytes(Float64List samples, int rate) {
    const numChannels = 1;
    const bitsPerSample = 16;
    final byteRate = rate * numChannels * (bitsPerSample ~/ 8);
    final blockAlign = numChannels * (bitsPerSample ~/ 8);
    final dataSize = samples.length * (bitsPerSample ~/ 8);
    final fileSize = 36 + dataSize;

    final buffer = ByteData(44 + dataSize);

    // RIFF header
    buffer.setUint8(0, 0x52); // 'R'
    buffer.setUint8(1, 0x49); // 'I'
    buffer.setUint8(2, 0x46); // 'F'
    buffer.setUint8(3, 0x46); // 'F'
    buffer.setUint32(4, fileSize, Endian.little);
    buffer.setUint8(8, 0x57);  // 'W'
    buffer.setUint8(9, 0x41);  // 'A'
    buffer.setUint8(10, 0x56); // 'V'
    buffer.setUint8(11, 0x45); // 'E'

    // fmt sub-chunk
    buffer.setUint8(12, 0x66); // 'f'
    buffer.setUint8(13, 0x6D); // 'm'
    buffer.setUint8(14, 0x74); // 't'
    buffer.setUint8(15, 0x20); // ' '
    buffer.setUint32(16, 16, Endian.little);
    buffer.setUint16(20, 1, Endian.little); // PCM
    buffer.setUint16(22, numChannels, Endian.little);
    buffer.setUint32(24, rate, Endian.little);
    buffer.setUint32(28, byteRate, Endian.little);
    buffer.setUint16(32, blockAlign, Endian.little);
    buffer.setUint16(34, bitsPerSample, Endian.little);

    // data sub-chunk
    buffer.setUint8(36, 0x64); // 'd'
    buffer.setUint8(37, 0x61); // 'a'
    buffer.setUint8(38, 0x74); // 't'
    buffer.setUint8(39, 0x61); // 'a'
    buffer.setUint32(40, dataSize, Endian.little);

    int offset = 44;
    for (int i = 0; i < samples.length; i++) {
      final clamped = samples[i].clamp(-1.0, 1.0);
      final sampleInt = (clamped * 32767).toInt();
      buffer.setInt16(offset, sampleInt, Endian.little);
      offset += 2;
    }

    return buffer.buffer.asUint8List();
  }
}
