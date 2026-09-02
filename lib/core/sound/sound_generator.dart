import 'dart:math';
import 'dart:typed_data';

enum AlarmSoundPreset {
  melodicChime, // Warm Westminster / Cathedral bell chime (C4-E4-G4-C5)
  zenBell,      // Deep resonant Tibetan singing bowl (130Hz bass fundamental)
  cyberPulse,   // Deep ambient synth chord
  digitalBeep,  // Modern minimalist acoustic ding
}

class SoundGenerator {
  static Uint8List createWav(AlarmSoundPreset preset) {
    switch (preset) {
      case AlarmSoundPreset.melodicChime:
        return _generateMelodicChime();
      case AlarmSoundPreset.zenBell:
        return _generateZenBell();
      case AlarmSoundPreset.cyberPulse:
        return _generateCyberPulse();
      case AlarmSoundPreset.digitalBeep:
        return _generateDigitalBeep();
    }
  }

  /// Warm, rich Cathedral / Westminster bell chime (C4, E4, G4, C5)
  static Uint8List _generateMelodicChime() {
    const sampleRate = 44100;
    const totalDuration = 3.2; // seconds
    final numSamples = (sampleRate * totalDuration).toInt();
    final samples = Float64List(numSamples);

    // Warm tenor octave notes
    final notes = [
      {'freq': 261.63, 'start': 0.0, 'decay': 2.4},   // C4
      {'freq': 329.63, 'start': 0.28, 'decay': 2.4},  // E4
      {'freq': 392.00, 'start': 0.56, 'decay': 2.6},  // G4
      {'freq': 523.25, 'start': 0.84, 'decay': 2.8},  // C5
    ];

    for (final note in notes) {
      final freq = note['freq'] as double;
      final start = note['start'] as double;
      final decay = note['decay'] as double;
      final startIdx = (start * sampleRate).toInt();

      for (int i = startIdx; i < numSamples; i++) {
        final t = (i - startIdx) / sampleRate;
        // Soft felt hammer attack (18ms) + long smooth acoustic decay
        final attack = (t < 0.018) ? (t / 0.018) : 1.0;
        final envelope = attack * exp(-2.2 * t / decay);
        if (envelope < 0.0001) continue;

        // Fundamental (deep & warm) + soft subtle octave & fifth harmonics
        final wave = 0.70 * sin(2 * pi * freq * t) +
            0.20 * sin(2 * pi * (freq * 2) * t) +
            0.10 * sin(2 * pi * (freq * 3) * t);

        samples[i] += wave * envelope * 0.35;
      }
    }

    return _samplesToWavBytes(samples, sampleRate);
  }

  /// Deep, authentic Tibetan singing bowl with 130.8Hz bass fundamental and soothing wa-wa resonance
  static Uint8List _generateZenBell() {
    const sampleRate = 44100;
    const totalDuration = 4.0; // 4 second rich decay
    final numSamples = (sampleRate * totalDuration).toInt();
    final samples = Float64List(numSamples);

    // Authentic non-harmonic singing bowl modes
    const f0 = 130.81; // C3 rich bass fundamental
    final modes = [
      {'freq': f0, 'amp': 0.55, 'decay': 3.8},          // Deep fundamental body
      {'freq': f0 * 2.76, 'amp': 0.25, 'decay': 3.0},   // 361 Hz mid bowl resonance
      {'freq': f0 * 5.40, 'amp': 0.12, 'decay': 2.2},   // 706 Hz soft rim overtone
    ];

    for (int i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      // Soft padded mallet strike attack (30ms)
      final attack = (t < 0.03) ? (t / 0.03) : 1.0;
      double sampleVal = 0.0;

      for (final mode in modes) {
        final freq = mode['freq'] as double;
        final amp = mode['amp'] as double;
        final decay = mode['decay'] as double;
        final env = attack * exp(-1.8 * t / decay);

        // Gentle 0.8Hz amplitude beating characteristic of heavy acoustic bronze bowls
        final pulse = 0.85 + 0.15 * sin(2 * pi * 0.8 * t);
        sampleVal += sin(2 * pi * freq * t) * env * amp * pulse;
      }

      samples[i] = sampleVal * 0.45;
    }

    return _samplesToWavBytes(samples, sampleRate);
  }

  /// Deep, warm ambient synthesizer swell
  static Uint8List _generateCyberPulse() {
    const sampleRate = 44100;
    const totalDuration = 2.4;
    final numSamples = (sampleRate * totalDuration).toInt();
    final samples = Float64List(numSamples);

    // Warm mid-bass synth chord: A2 (110Hz), E3 (164.8Hz), A3 (220Hz), C#4 (277.18Hz)
    final chord = [110.0, 164.81, 220.0, 277.18];

    for (int i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      final attack = (t < 0.05) ? (t / 0.05) : 1.0;
      final env = attack * exp(-2.2 * t);
      double val = 0.0;

      for (final f in chord) {
        val += sin(2 * pi * f * t) + 0.25 * sin(2 * pi * (f * 2) * t);
      }

      samples[i] = val * env * 0.18;
    }

    return _samplesToWavBytes(samples, sampleRate);
  }

  /// Modern minimalist acoustic ding (warm single A4 440Hz glass bell)
  static Uint8List _generateDigitalBeep() {
    const sampleRate = 44100;
    const totalDuration = 1.8;
    final numSamples = (sampleRate * totalDuration).toInt();
    final samples = Float64List(numSamples);

    const freq = 440.0; // A4 warm concert pitch

    for (int i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      final attack = (t < 0.008) ? (t / 0.008) : 1.0;
      final env = attack * exp(-3.0 * t);

      final wave = 0.75 * sin(2 * pi * freq * t) +
          0.20 * sin(2 * pi * (freq * 2) * t) +
          0.05 * sin(2 * pi * (freq * 3) * t);

      samples[i] = wave * env * 0.40;
    }

    return _samplesToWavBytes(samples, sampleRate);
  }

  /// Encodes normalized Float64 audio samples into a standard 16-bit PCM WAV container
  static Uint8List _samplesToWavBytes(Float64List samples, int sampleRate) {
    const numChannels = 1;
    const bitsPerSample = 16;
    final byteRate = sampleRate * numChannels * (bitsPerSample ~/ 8);
    final blockAlign = numChannels * (bitsPerSample ~/ 8);
    final dataSize = samples.length * (bitsPerSample ~/ 8);
    final fileSize = 36 + dataSize;

    final buffer = ByteData(44 + dataSize);

    // RIFF chunk descriptor
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
    buffer.setUint32(16, 16, Endian.little); // Subchunk1Size (16 for PCM)
    buffer.setUint16(20, 1, Endian.little);  // AudioFormat (1 for PCM)
    buffer.setUint16(22, numChannels, Endian.little);
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, byteRate, Endian.little);
    buffer.setUint16(32, blockAlign, Endian.little);
    buffer.setUint16(34, bitsPerSample, Endian.little);

    // data sub-chunk
    buffer.setUint8(36, 0x64); // 'd'
    buffer.setUint8(37, 0x61); // 'a'
    buffer.setUint8(38, 0x74); // 't'
    buffer.setUint8(39, 0x61); // 'a'
    buffer.setUint32(40, dataSize, Endian.little);

    // Write PCM 16-bit samples
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
