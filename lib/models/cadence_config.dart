import 'dart:math';

/// Cadence tempo modes supported by the Pacing Metronome engine.
enum CadenceMode {
  none,
  fixed,  // Constant steady BPM
  wave,   // Sinusoidal wave between minBpm and maxBpm
  peak,   // Pyramid peak: ramp up to midpoint, then cooldown
  ramp,   // Accelerando ramp: progressively speeds up to maxBpm
  random, // Surprise random tempo jumps between minBpm and maxBpm
}

/// Sound tone synthesized for each beat.
enum CadenceSoundTone {
  woodblock,
  tick,
  beep,
  bass,
  bell,
}

/// Trend of tempo at the current moment.
enum TempoTrend {
  steady,
  accelerating,
  decelerating,
}

/// Vibration style on connected Bluetooth novelty hardware during an order.
enum CadenceToyMode {
  pulse,      // Beat Pulses: Sharp physical bursts on every metronome beat
  continuous, // Steady Buzz: Continuous vibration rising and falling with the pattern
}

extension CadenceToyModeExtension on CadenceToyMode {
  String get displayName {
    switch (this) {
      case CadenceToyMode.pulse:
        return 'Beat Pulses';
      case CadenceToyMode.continuous:
        return 'Steady Buzz';
    }
  }

  String get description {
    switch (this) {
      case CadenceToyMode.pulse:
        return 'Sharp physical bursts on every metronome beat';
      case CadenceToyMode.continuous:
        return 'Continuous humming vibration that rises and falls with the pattern';
    }
  }
}

/// Configuration for a pacing cadence on an Action Routine or metronome session.
class CadenceConfig {
  final CadenceMode mode;
  final int bpm;                  // For fixed mode (e.g. 60)
  final int minBpm;               // Min BPM for variable modes (e.g. 30)
  final int maxBpm;               // Max BPM for variable modes (e.g. 120)
  final int waveCount;            // Swell cycles for wave mode (e.g. 2)
  final int randomIntervalSeconds;// How often random mode shifts tempo (e.g. 15s)
  final CadenceSoundTone soundTone;
  final bool enableAudio;
  final bool enableHaptics;
  final bool enableVisual;
  final bool enableToy;
  final CadenceToyMode toyMode;
  final int toyMinPower;
  final int toyMaxPower;

  const CadenceConfig({
    this.mode = CadenceMode.fixed,
    this.bpm = 60,
    this.minBpm = 30,
    this.maxBpm = 120,
    this.waveCount = 2,
    this.randomIntervalSeconds = 15,
    this.soundTone = CadenceSoundTone.woodblock,
    this.enableAudio = true,
    this.enableHaptics = true,
    this.enableVisual = true,
    this.enableToy = true,
    this.toyMode = CadenceToyMode.pulse,
    this.toyMinPower = 1,
    this.toyMaxPower = 20,
  });

  /// Factory for a default fixed BPM cadence
  factory CadenceConfig.fixed({
    int bpm = 60,
    CadenceSoundTone tone = CadenceSoundTone.woodblock,
    CadenceToyMode toyMode = CadenceToyMode.pulse,
    int toyMinPower = 1,
    int toyMaxPower = 20,
  }) {
    return CadenceConfig(
      mode: CadenceMode.fixed,
      bpm: bpm.clamp(10, 300),
      soundTone: tone,
      toyMode: toyMode,
      toyMinPower: toyMinPower.clamp(1, 20),
      toyMaxPower: toyMaxPower.clamp(1, 20),
    );
  }

  /// Factory for wave / rollercoaster cadence
  factory CadenceConfig.wave({
    int minBpm = 30,
    int maxBpm = 120,
    int waveCount = 2,
    CadenceSoundTone tone = CadenceSoundTone.woodblock,
    CadenceToyMode toyMode = CadenceToyMode.pulse,
    int toyMinPower = 1,
    int toyMaxPower = 20,
  }) {
    return CadenceConfig(
      mode: CadenceMode.wave,
      minBpm: minBpm.clamp(10, 300),
      maxBpm: maxBpm.clamp(10, 300),
      waveCount: waveCount.clamp(1, 10),
      soundTone: tone,
      toyMode: toyMode,
      toyMinPower: toyMinPower.clamp(1, 20),
      toyMaxPower: toyMaxPower.clamp(1, 20),
    );
  }

  /// Factory for peak / pyramid cadence
  factory CadenceConfig.peak({
    int minBpm = 30,
    int maxBpm = 120,
    CadenceSoundTone tone = CadenceSoundTone.woodblock,
    CadenceToyMode toyMode = CadenceToyMode.pulse,
    int toyMinPower = 1,
    int toyMaxPower = 20,
  }) {
    return CadenceConfig(
      mode: CadenceMode.peak,
      minBpm: minBpm.clamp(10, 300),
      maxBpm: maxBpm.clamp(10, 300),
      soundTone: tone,
      toyMode: toyMode,
      toyMinPower: toyMinPower.clamp(1, 20),
      toyMaxPower: toyMaxPower.clamp(1, 20),
    );
  }

  /// Factory for ramp / accelerando cadence
  factory CadenceConfig.ramp({
    int minBpm = 30,
    int maxBpm = 120,
    CadenceSoundTone tone = CadenceSoundTone.woodblock,
    CadenceToyMode toyMode = CadenceToyMode.pulse,
    int toyMinPower = 1,
    int toyMaxPower = 20,
  }) {
    return CadenceConfig(
      mode: CadenceMode.ramp,
      minBpm: minBpm.clamp(10, 300),
      maxBpm: maxBpm.clamp(10, 300),
      soundTone: tone,
      toyMode: toyMode,
      toyMinPower: toyMinPower.clamp(1, 20),
      toyMaxPower: toyMaxPower.clamp(1, 20),
    );
  }

  /// Factory for random tempo shift cadence
  factory CadenceConfig.random({
    int minBpm = 30,
    int maxBpm = 120,
    int intervalSeconds = 15,
    CadenceSoundTone tone = CadenceSoundTone.woodblock,
    CadenceToyMode toyMode = CadenceToyMode.pulse,
    int toyMinPower = 1,
    int toyMaxPower = 20,
  }) {
    return CadenceConfig(
      mode: CadenceMode.random,
      minBpm: minBpm.clamp(10, 300),
      maxBpm: maxBpm.clamp(10, 300),
      randomIntervalSeconds: intervalSeconds.clamp(3, 60),
      soundTone: tone,
      toyMode: toyMode,
      toyMinPower: toyMinPower.clamp(1, 20),
      toyMaxPower: toyMaxPower.clamp(1, 20),
    );
  }

  CadenceConfig copyWith({
    CadenceMode? mode,
    int? bpm,
    int? minBpm,
    int? maxBpm,
    int? waveCount,
    int? randomIntervalSeconds,
    CadenceSoundTone? soundTone,
    bool? enableAudio,
    bool? enableHaptics,
    bool? enableVisual,
    bool? enableToy,
    CadenceToyMode? toyMode,
    int? toyMinPower,
    int? toyMaxPower,
  }) {
    return CadenceConfig(
      mode: mode ?? this.mode,
      bpm: bpm ?? this.bpm,
      minBpm: minBpm ?? this.minBpm,
      maxBpm: maxBpm ?? this.maxBpm,
      waveCount: waveCount ?? this.waveCount,
      randomIntervalSeconds: randomIntervalSeconds ?? this.randomIntervalSeconds,
      soundTone: soundTone ?? this.soundTone,
      enableAudio: enableAudio ?? this.enableAudio,
      enableHaptics: enableHaptics ?? this.enableHaptics,
      enableVisual: enableVisual ?? this.enableVisual,
      enableToy: enableToy ?? this.enableToy,
      toyMode: toyMode ?? this.toyMode,
      toyMinPower: toyMinPower ?? this.toyMinPower,
      toyMaxPower: toyMaxPower ?? this.toyMaxPower,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'mode': mode.name,
      'bpm': bpm,
      'minBpm': minBpm,
      'maxBpm': maxBpm,
      'waveCount': waveCount,
      'randomIntervalSeconds': randomIntervalSeconds,
      'soundTone': soundTone.name,
      'enableAudio': enableAudio,
      'enableHaptics': enableHaptics,
      'enableVisual': enableVisual,
      'enableToy': enableToy,
      'toyMode': toyMode.name,
      'toyMinPower': toyMinPower,
      'toyMaxPower': toyMaxPower,
    };
  }

  factory CadenceConfig.fromJson(Map<String, dynamic> json) {
    return CadenceConfig(
      mode: CadenceMode.values.firstWhere(
        (e) => e.name == json['mode'],
        orElse: () => CadenceMode.fixed,
      ),
      bpm: (json['bpm'] as num?)?.toInt() ?? 60,
      minBpm: (json['minBpm'] as num?)?.toInt() ?? 30,
      maxBpm: (json['maxBpm'] as num?)?.toInt() ?? 120,
      waveCount: (json['waveCount'] as num?)?.toInt() ?? 2,
      randomIntervalSeconds: (json['randomIntervalSeconds'] as num?)?.toInt() ?? 15,
      soundTone: CadenceSoundTone.values.firstWhere(
        (e) => e.name == json['soundTone'],
        orElse: () => CadenceSoundTone.woodblock,
      ),
      enableAudio: json['enableAudio'] as bool? ?? true,
      enableHaptics: json['enableHaptics'] as bool? ?? true,
      enableVisual: json['enableVisual'] as bool? ?? true,
      enableToy: json['enableToy'] as bool? ?? true,
      toyMode: json['toyMode'] == 'continuous'
          ? CadenceToyMode.continuous
          : CadenceToyMode.pulse,
      toyMinPower: (json['toyMinPower'] as num?)?.toInt() ?? 1,
      toyMaxPower: (json['toyMaxPower'] as num?)?.toInt() ?? 20,
    );
  }

  /// Calculates the BPM at a given point in time [elapsedSeconds] over total [totalDurationSeconds].
  ///
  /// Guarantees that the returned value is always clamped between [minBpm] and [maxBpm] (or [bpm] for fixed).
  int calculateBpmAt(double elapsedSeconds, int totalDurationSeconds, {int seed = 42}) {
    if (mode == CadenceMode.none) return 0;
    if (mode == CadenceMode.fixed) return bpm.clamp(10, 300);

    final low = min(minBpm, maxBpm).clamp(10, 300);
    final high = max(minBpm, maxBpm).clamp(10, 300);
    if (low == high) return low;

    final progress = totalDurationSeconds > 0
        ? (elapsedSeconds / totalDurationSeconds).clamp(0.0, 1.0)
        : 0.0;

    switch (mode) {
      case CadenceMode.fixed:
      case CadenceMode.none:
        return bpm.clamp(10, 300);

      case CadenceMode.wave:
        // Cosine wave oscillation: starts at min, peaks at max, returns to min over waveCount cycles
        final cycles = waveCount.clamp(1, 10);
        final factor = (1.0 - cos(2.0 * pi * cycles * progress)) / 2.0;
        final result = low + (high - low) * factor;
        return result.round().clamp(low, high);

      case CadenceMode.peak:
        // Pyramid: ramp from min to max at progress = 0.5, then cooldown back to min at 1.0
        final factor = progress <= 0.5
            ? (progress * 2.0)
            : ((1.0 - progress) * 2.0);
        final result = low + (high - low) * factor;
        return result.round().clamp(low, high);

      case CadenceMode.ramp:
        // Accelerando ramp: progressively accelerates from min to max over the duration
        final result = low + (high - low) * progress;
        return result.round().clamp(low, high);

      case CadenceMode.random:
        // Stepped surprise jumps every randomIntervalSeconds
        final interval = randomIntervalSeconds.clamp(3, 60);
        final stepIndex = (elapsedSeconds / interval).floor();
        // Deterministic pseudo-random generation per step so playback is consistent
        final stepRng = Random(seed + stepIndex * 7919);
        final factor = stepRng.nextDouble();
        final result = low + (high - low) * factor;
        return result.round().clamp(low, high);
    }
  }

  /// Calculates the general trend of the tempo at [elapsedSeconds] compared to a short moment ahead.
  TempoTrend calculateTrendAt(double elapsedSeconds, int totalDurationSeconds, {int seed = 42}) {
    if (mode == CadenceMode.fixed || mode == CadenceMode.none) {
      return TempoTrend.steady;
    }

    final currentBpm = calculateBpmAt(elapsedSeconds, totalDurationSeconds, seed: seed);
    final lookahead = min(totalDurationSeconds.toDouble(), elapsedSeconds + 1.0);
    final nextBpm = calculateBpmAt(lookahead, totalDurationSeconds, seed: seed);

    if (nextBpm > currentBpm) return TempoTrend.accelerating;
    if (nextBpm < currentBpm) return TempoTrend.decelerating;
    return TempoTrend.steady;
  }

  /// Calculates normalized intensity curve position (0.0 to 1.0) at [elapsedSeconds].
  double calculateIntensityFactorAt(double elapsedSeconds, int totalDurationSeconds, {int seed = 42}) {
    if (mode == CadenceMode.none) return 0.0;
    if (mode == CadenceMode.fixed) return 1.0;

    final progress = totalDurationSeconds > 0
        ? (elapsedSeconds / totalDurationSeconds).clamp(0.0, 1.0)
        : 0.0;

    switch (mode) {
      case CadenceMode.fixed:
      case CadenceMode.none:
        return 1.0;

      case CadenceMode.wave:
        final cycles = waveCount.clamp(1, 10);
        return (1.0 - cos(2.0 * pi * cycles * progress)) / 2.0;

      case CadenceMode.peak:
        return progress <= 0.5
            ? (progress * 2.0)
            : ((1.0 - progress) * 2.0);

      case CadenceMode.ramp:
        return progress;

      case CadenceMode.random:
        final interval = randomIntervalSeconds.clamp(3, 60);
        final stepIndex = (elapsedSeconds / interval).floor();
        final stepRng = Random(seed + stepIndex * 7919);
        return stepRng.nextDouble();
    }
  }

  /// Calculates target continuous vibration motor power (1 to 20) at [elapsedSeconds].
  ///
  /// Maps the cadence curve between [toyMinPower] and [toyMaxPower], bounded by [maxCeiling] if provided.
  int calculateToySpeedAt(double elapsedSeconds, int totalDurationSeconds, {int seed = 42, int? maxCeiling}) {
    final ceiling = (maxCeiling ?? 20).clamp(1, 20);
    final minP = toyMinPower.clamp(1, ceiling);
    final maxP = toyMaxPower.clamp(minP, ceiling);

    if (mode == CadenceMode.fixed) {
      return maxP;
    }

    final factor = calculateIntensityFactorAt(elapsedSeconds, totalDurationSeconds, seed: seed);
    final calculated = minP + (factor * (maxP - minP)).round();
    return calculated.clamp(minP, ceiling);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CadenceConfig &&
        other.mode == mode &&
        other.bpm == bpm &&
        other.minBpm == minBpm &&
        other.maxBpm == maxBpm &&
        other.waveCount == waveCount &&
        other.randomIntervalSeconds == randomIntervalSeconds &&
        other.soundTone == soundTone &&
        other.enableAudio == enableAudio &&
        other.enableHaptics == enableHaptics &&
        other.enableVisual == enableVisual &&
        other.enableToy == enableToy &&
        other.toyMode == toyMode &&
        other.toyMinPower == toyMinPower &&
        other.toyMaxPower == toyMaxPower;
  }

  @override
  int get hashCode => Object.hash(
        mode,
        bpm,
        minBpm,
        maxBpm,
        waveCount,
        randomIntervalSeconds,
        soundTone,
        enableAudio,
        enableHaptics,
        enableVisual,
        enableToy,
        toyMode,
        toyMinPower,
        toyMaxPower,
      );
}

extension CadenceModeExtension on CadenceMode {
  String get displayName {
    switch (this) {
      case CadenceMode.none:
        return 'None';
      case CadenceMode.fixed:
        return 'Fixed BPM';
      case CadenceMode.wave:
        return 'Wave';
      case CadenceMode.peak:
        return 'Peak';
      case CadenceMode.ramp:
        return 'Ramp';
      case CadenceMode.random:
        return 'Random';
    }
  }
}
