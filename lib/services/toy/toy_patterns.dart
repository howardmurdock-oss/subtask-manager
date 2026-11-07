import 'dart:math';

/// One-tap vibration patterns for live control.
///
/// A pattern is a shape over time, from 0 (still) to 1 (full). It always runs
/// on the device the toy is connected to, so its timing is exact however slow
/// the network is: a partner sends only "play wave at strength 14".
enum ToyPattern {
  pulse,
  wave,
  escalate,
  heartbeat,
  tease,
  staircase,
}

extension ToyPatternInfo on ToyPattern {
  String get displayName {
    switch (this) {
      case ToyPattern.pulse:
        return 'Pulse';
      case ToyPattern.wave:
        return 'Wave';
      case ToyPattern.escalate:
        return 'Escalate';
      case ToyPattern.heartbeat:
        return 'Heartbeat';
      case ToyPattern.tease:
        return 'Tease';
      case ToyPattern.staircase:
        return 'Staircase';
    }
  }

  String get description {
    switch (this) {
      case ToyPattern.pulse:
        return 'On and off, every half second';
      case ToyPattern.wave:
        return 'Rises and falls smoothly';
      case ToyPattern.escalate:
        return 'Builds over 30 seconds, then holds';
      case ToyPattern.heartbeat:
        return 'A double beat, over and over';
      case ToyPattern.tease:
        return 'Short bursts at unpredictable moments';
      case ToyPattern.staircase:
        return 'Steps up in four stages, then starts again';
    }
  }

  /// Strength at [elapsed] into the pattern, 0 to 1. [seed] makes Tease the
  /// same on every replay of one run, and different between runs.
  double levelAt(Duration elapsed, {int seed = 0}) {
    final ms = elapsed.inMilliseconds;
    switch (this) {
      case ToyPattern.pulse:
        return (ms ~/ 500).isEven ? 1 : 0;
      case ToyPattern.wave:
        // A 6-second swell that never quite stops, so it reads as one motion.
        final phase = (ms % 6000) / 6000;
        return 0.15 + 0.85 * (0.5 - 0.5 * cos(phase * 2 * pi));
      case ToyPattern.escalate:
        return min(1.0, 0.1 + 0.9 * ms / 30000);
      case ToyPattern.heartbeat:
        final t = ms % 1200;
        if (t < 120) return 1;
        if (t < 250) return 0;
        if (t < 370) return 0.8;
        return 0;
      case ToyPattern.tease:
        // Each 1.5-second slot is either a burst or a gap, decided by the seed.
        final slot = ms ~/ 1500;
        final burst = Random(seed * 7919 + slot).nextDouble() < 0.4;
        if (!burst) return 0;
        final within = ms % 1500;
        return within < 700 ? 1 : 0;
      case ToyPattern.staircase:
        final step = (ms % 16000) ~/ 4000;
        return (step + 1) / 4;
    }
  }

  /// [levelAt] scaled to a speed from 0 to [strength] (1 to 20).
  int speedAt(Duration elapsed, int strength, {int seed = 0}) {
    final s = strength.clamp(1, 20);
    final level = levelAt(elapsed, seed: seed).clamp(0.0, 1.0);
    if (level <= 0) return 0;
    return max(1, (level * s).round());
  }

  static ToyPattern? fromName(String? name) {
    for (final p in ToyPattern.values) {
      if (p.name == name) return p;
    }
    return null;
  }
}
