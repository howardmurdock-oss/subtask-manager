import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/cadence_config.dart';
import '../cadence_engine.dart';
import 'toy_patterns.dart';
import 'toy_service.dart';

/// What the toy is doing under direct control.
enum ToyActivity { idle, level, pattern, metronome }

/// Where speeds go. The real one is the Bluetooth toy; tests use a recorder.
abstract class ToyOutput {
  void setSpeed(int speed);
  void stop();
}

class _BluetoothOutput implements ToyOutput {
  @override
  void setSpeed(int speed) => ToyService.instance.setVibrateSpeed(speed);

  @override
  void stop() => ToyService.instance.stopVibration();
}

/// Plays direct control on the device the toy is connected to: a held level,
/// a pattern, or a metronome. Used for your own toy from the control panel,
/// and for a partner's commands arriving over live control - either way the
/// timing is local, so only the choice travels.
class ToyPlayer extends ChangeNotifier {
  ToyPlayer({ToyOutput? output, this.patternTick = const Duration(milliseconds: 100)})
      : _output = output ?? _BluetoothOutput();

  static final ToyPlayer instance = ToyPlayer();

  final ToyOutput _output;
  final Duration patternTick;

  ToyActivity _activity = ToyActivity.idle;
  int _level = 0;
  ToyPattern? _pattern;
  int _strength = 12;
  CadenceConfig? _cadence;
  int _cadenceSeconds = 0;

  Timer? _patternTimer;
  Stopwatch? _patternClock;
  int _patternSeed = 0;
  CadenceEngine? _engine;

  ToyActivity get activity => _activity;
  int get level => _level;
  ToyPattern? get pattern => _pattern;
  int get strength => _strength;
  CadenceConfig? get cadence => _cadence;
  int get cadenceSeconds => _cadenceSeconds;
  int? get currentBpm => _engine?.currentBpm;
  double? get metronomeProgress => _engine?.progress;
  bool get isActive => _activity != ToyActivity.idle;

  /// Holds the toy at [speed] (0 to 20). 0 is the same as [stop].
  void setLevel(int speed) {
    final s = speed.clamp(0, 20);
    if (s == 0) {
      stop();
      return;
    }
    if (_activity != ToyActivity.level) _halt();
    _activity = ToyActivity.level;
    _level = s;
    _output.setSpeed(s);
    notifyListeners();
  }

  /// Plays [pattern] up to [strength] (1 to 20) until stopped.
  void playPattern(ToyPattern pattern, int strength) {
    _halt();
    _activity = ToyActivity.pattern;
    _pattern = pattern;
    _strength = strength.clamp(1, 20);
    _patternSeed = DateTime.now().millisecondsSinceEpoch & 0x7fffffff;
    _patternClock = Stopwatch()..start();
    _tickPattern();
    _patternTimer = Timer.periodic(patternTick, (_) => _tickPattern());
    notifyListeners();
  }

  /// Advances a pattern by [elapsed] - for tests, which cannot wait.
  @visibleForTesting
  int patternSpeedAt(Duration elapsed) =>
      _pattern?.speedAt(elapsed, _strength, seed: _patternSeed) ?? 0;

  void _tickPattern() {
    final p = _pattern;
    final clock = _patternClock;
    if (p == null || clock == null) return;
    _output.setSpeed(p.speedAt(clock.elapsed, _strength, seed: _patternSeed));
  }

  /// Changes how strong the running pattern or metronome is, without
  /// restarting it.
  void setStrength(int strength) {
    _strength = strength.clamp(1, 20);
    if (_activity == ToyActivity.metronome) {
      ToyService.instance.intensityOverride = _strength;
    } else if (_activity == ToyActivity.pattern) {
      _tickPattern();
    }
    notifyListeners();
  }

  /// Runs a metronome on the toy (and, if [config] says so, its sound on this
  /// device) for [seconds], or until stopped when 0.
  void startMetronome(CadenceConfig config, {int seconds = 0, int? strength}) {
    _halt();
    if (strength != null) _strength = strength.clamp(1, 20);
    _activity = ToyActivity.metronome;
    _cadence = config.copyWith(enableToy: true);
    _cadenceSeconds = seconds < 0 ? 0 : seconds;
    ToyService.instance.intensityOverride = _strength;
    final engine = CadenceEngine(config: _cadence, totalDurationSeconds: _cadenceSeconds);
    _engine = engine;
    engine.addListener(_onEngineChanged);
    engine.start();
    notifyListeners();
  }

  /// Changes a running metronome's settings in place.
  void updateMetronome(CadenceConfig config) {
    final engine = _engine;
    if (engine == null || _activity != ToyActivity.metronome) return;
    _cadence = config.copyWith(enableToy: true);
    engine.updateConfig(_cadence!);
    notifyListeners();
  }

  void _onEngineChanged() {
    final engine = _engine;
    if (engine == null) return;
    if (!engine.isRunning && _activity == ToyActivity.metronome) {
      // Ran its full length. Tidied up after the engine finishes notifying:
      // disposing a notifier from inside its own notification is an error.
      _activity = ToyActivity.idle;
      scheduleMicrotask(() {
        if (identical(_engine, engine)) _halt();
      });
    }
    notifyListeners();
  }

  /// Stops everything and stills the toy.
  void stop() {
    _halt();
    _activity = ToyActivity.idle;
    _level = 0;
    _output.stop();
    notifyListeners();
  }

  void _halt() {
    _patternTimer?.cancel();
    _patternTimer = null;
    _patternClock = null;
    final engine = _engine;
    _engine = null;
    if (engine != null) {
      engine.removeListener(_onEngineChanged);
      engine.stop();
      engine.dispose();
      ToyService.instance.intensityOverride = null;
    }
  }

  @override
  void dispose() {
    _halt();
    super.dispose();
  }
}
