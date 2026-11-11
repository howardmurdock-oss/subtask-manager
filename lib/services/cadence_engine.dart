import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/sound/cadence_sound_generator.dart';
import '../models/cadence_config.dart';
import 'toy/toy_service.dart';

/// Information payload emitted on every beat tick of the Cadence engine.
class CadenceTick {
  final int beatNumber;
  final int currentBpm;
  final double progress; // 0.0 to 1.0
  final double elapsedSeconds;
  final int totalDurationSeconds;
  final CadenceMode mode;
  final TempoTrend trend;
  final bool isTempoShift; // True when a dynamic shift or peak occurs

  const CadenceTick({
    required this.beatNumber,
    required this.currentBpm,
    required this.progress,
    required this.elapsedSeconds,
    required this.totalDurationSeconds,
    required this.mode,
    required this.trend,
    this.isTempoShift = false,
  });
}

/// The runtime engine that generates pacing metronome beats according to dynamic cadence curves.
class CadenceEngine extends ChangeNotifier {
  CadenceConfig _config;
  int _totalDurationSeconds;
  final int _seed;

  bool _isRunning = false;
  bool _isPaused = false;
  double _elapsedSeconds = 0.0;
  int _currentBpm = 60;
  int _beatCount = 0;
  TempoTrend _trend = TempoTrend.steady;

  Timer? _beatTimer;
  Timer? _continuousToyTimer;
  DateTime? _lastBeatTime;
  int _lastRandomStepIndex = -1;

  final StreamController<CadenceTick> _tickController = StreamController<CadenceTick>.broadcast();

  // Dual audio players to allow smooth overlapping clicks even at high BPMs
  AudioPlayer? _playerA;
  AudioPlayer? _playerB;
  AudioPlayer? _playerShift;
  bool _usePlayerA = true;

  /// What each player has loaded ('shift' or a tone), and the load itself.
  /// A beat only rewinds and plays: loading a sound takes long enough (up
  /// to most of a second) that the toy, told over Bluetooth at the same
  /// moment, would buzz well before the click is heard.
  final Map<AudioPlayer, Object> _loadedKey = {};
  final Map<AudioPlayer, Future<bool>> _loading = {};

  /// Counts starts, so a start still waiting on its sounds is dropped when
  /// stopped or started again meanwhile.
  int _startGeneration = 0;

  // Unit-testing hooks
  void Function(CadenceTick tick)? onTickCallback;

  CadenceEngine({
    CadenceConfig? config,
    int totalDurationSeconds = 0,
    int seed = 42,
    AudioPlayer? playerA,
    AudioPlayer? playerB,
  })  : _config = config ?? const CadenceConfig(),
        _totalDurationSeconds = totalDurationSeconds,
        _seed = seed,
        _playerA = playerA,
        _playerB = playerB {
    _currentBpm = _config.calculateBpmAt(0, _totalDurationSeconds, seed: _seed);
    _trend = _config.calculateTrendAt(0, _totalDurationSeconds, seed: _seed);
  }

  CadenceConfig get config => _config;
  int get totalDurationSeconds => _totalDurationSeconds;
  bool get isRunning => _isRunning;
  bool get isPaused => _isPaused;
  double get elapsedSeconds => _elapsedSeconds;
  int get currentBpm => _currentBpm;
  int get beatCount => _beatCount;
  TempoTrend get trend => _trend;
  double get progress => _totalDurationSeconds > 0
      ? (_elapsedSeconds / _totalDurationSeconds).clamp(0.0, 1.0)
      : 0.0;

  Stream<CadenceTick> get ticks => _tickController.stream;

  void updateConfig(CadenceConfig newConfig) {
    _config = newConfig;
    _currentBpm = _config.calculateBpmAt(_elapsedSeconds, _totalDurationSeconds, seed: _seed);
    _trend = _config.calculateTrendAt(_elapsedSeconds, _totalDurationSeconds, seed: _seed);
    if (_isRunning && !_isPaused) {
      // A new tone (or the tempo-shift cue) is loaded now, not on a beat.
      if (_config.enableAudio) {
        _initAudioPlayers();
        _preloadClicks();
      }
      if (_config.enableToy && _config.toyMode == CadenceToyMode.continuous) {
        _startContinuousToyLoop();
      } else {
        _continuousToyTimer?.cancel();
        _continuousToyTimer = null;
        if (!_config.enableToy) {
          ToyService.instance.stopVibration();
        }
      }
    }
    notifyListeners();
  }

  void setTotalDuration(int seconds) {
    _totalDurationSeconds = seconds;
    notifyListeners();
  }

  void start({CadenceConfig? newConfig, int? durationSeconds}) {
    if (newConfig != null) _config = newConfig;
    if (durationSeconds != null) _totalDurationSeconds = durationSeconds;

    _initAudioPlayers();
    _isRunning = true;
    _isPaused = false;
    _elapsedSeconds = 0.0;
    _beatCount = 0;
    _lastBeatTime = DateTime.now();
    _lastRandomStepIndex = -1;

    final generation = ++_startGeneration;
    void begin() {
      if (generation != _startGeneration || !_isRunning) return;
      _lastBeatTime = DateTime.now();
      _scheduleNextBeat(immediate: true);
      _startContinuousToyLoop();
      notifyListeners();
    }

    if (_config.enableAudio && _playerA != null) {
      // The first beat waits for its click to be loaded, so the two land
      // together from the start - but never longer than a second.
      _preloadClicks().timeout(const Duration(seconds: 1), onTimeout: () {}).whenComplete(begin);
      notifyListeners();
    } else {
      begin();
    }
  }

  void pause() {
    if (!_isRunning || _isPaused) return;
    _beatTimer?.cancel();
    _beatTimer = null;
    _continuousToyTimer?.cancel();
    _continuousToyTimer = null;
    _isPaused = true;
    _playerA?.stop().catchError((_) {});
    _playerB?.stop().catchError((_) {});
    ToyService.instance.stopVibration();
    notifyListeners();
  }

  void resume() {
    if (!_isRunning || !_isPaused) return;
    _isPaused = false;
    _lastBeatTime = DateTime.now();
    _scheduleNextBeat(immediate: true);
    _startContinuousToyLoop();
    notifyListeners();
  }

  void stop() {
    _startGeneration++;
    _beatTimer?.cancel();
    _beatTimer = null;
    _continuousToyTimer?.cancel();
    _continuousToyTimer = null;
    _isRunning = false;
    _isPaused = false;
    _playerA?.stop().catchError((_) {});
    _playerB?.stop().catchError((_) {});
    _playerShift?.stop().catchError((_) {});
    ToyService.instance.stopVibration();
    notifyListeners();
  }

  void reset() {
    stop();
    _elapsedSeconds = 0.0;
    _beatCount = 0;
    _currentBpm = _config.calculateBpmAt(0, _totalDurationSeconds, seed: _seed);
    _trend = _config.calculateTrendAt(0, _totalDurationSeconds, seed: _seed);
    notifyListeners();
  }

  void toggleAudio(bool enabled) {
    _config = _config.copyWith(enableAudio: enabled);
    if (enabled && _isRunning) {
      _initAudioPlayers();
      _preloadClicks();
    }
    notifyListeners();
  }

  void toggleHaptics(bool enabled) {
    _config = _config.copyWith(enableHaptics: enabled);
    notifyListeners();
  }

  void toggleToy(bool enabled) {
    _config = _config.copyWith(enableToy: enabled);
    if (!enabled) {
      _continuousToyTimer?.cancel();
      _continuousToyTimer = null;
      ToyService.instance.stopVibration();
    } else if (_isRunning && !_isPaused && _config.toyMode == CadenceToyMode.continuous) {
      _startContinuousToyLoop();
    }
    notifyListeners();
  }

  void setTone(CadenceSoundTone tone) {
    _config = _config.copyWith(soundTone: tone);
    if (_isRunning && _config.enableAudio) _preloadClicks();
    notifyListeners();
  }

  void _initAudioPlayers() {
    try {
      _playerA ??= AudioPlayer();
      _playerB ??= AudioPlayer();
      _playerShift ??= AudioPlayer();
    } catch (_) {}
  }

  /// Loads the current click into both beat players and the tempo-shift cue
  /// into its own, so no beat has to.
  Future<void> _preloadClicks() async {
    final tone = _config.soundTone;
    await Future.wait([
      for (final p in [_playerA, _playerB])
        if (p != null) _load(p, tone, () => CadenceSoundGenerator.getWav(tone)),
      if (_playerShift != null && _config.mode == CadenceMode.random)
        _load(_playerShift!, 'shift', CadenceSoundGenerator.getShiftCueWav),
    ]);
  }

  /// Android's ordinary player takes a couple of hundred milliseconds from
  /// "play" to sound - enough to land a click between two of the toy's
  /// pulses. Its low-latency player (SoundPool) is made for short sounds
  /// like these, but only plays files.
  static bool get _lowLatency => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static final Map<Object, Future<String>> _clickFiles = {};

  static Future<String> _clickFile(Object key, Uint8List Function() bytes) =>
      _clickFiles[key] ??= () async {
        final file = File('${Directory.systemTemp.path}/cadence_click_$key.wav');
        await file.writeAsBytes(bytes(), flush: true);
        return file.path;
      }();

  /// Loads [bytes] into [player] unless it already holds them. True when
  /// the player is ready to play them.
  Future<bool> _load(AudioPlayer player, Object key, Uint8List Function() bytes) {
    if (_loadedKey[player] == key) return _loading[player] ?? Future.value(true);
    _loadedKey[player] = key;
    final loading = () async {
      try {
        // Keep the sound after it finishes: the default throws it away,
        // and the next beat would have to load it all over again.
        await player.setReleaseMode(ReleaseMode.stop);
        if (_lowLatency) {
          final path = await _clickFile(key, bytes);
          await player.setPlayerMode(PlayerMode.lowLatency);
          await player
              .setSource(DeviceFileSource(path))
              // Ready or not by then, a beat may as well try.
              .timeout(const Duration(seconds: 2), onTimeout: () {});
        } else {
          await player.setSource(BytesSource(bytes()));
        }
        return true;
      } catch (_) {
        if (_loadedKey[player] == key) _loadedKey.remove(player);
        return false;
      }
    }();
    _loading[player] = loading;
    return loading;
  }

  /// Plays what [player] holds from the start, now if it is loaded.
  void _fire(AudioPlayer player, Object key, Uint8List Function() bytes) {
    final loading = _load(player, key, bytes);
    void go() {
      if (_lowLatency) {
        // SoundPool never says a sound has ended, so the player still
        // thinks it is playing and would ignore a plain resume.
        player.stop().then((_) => player.resume()).catchError((_) {});
      } else if (player.state == PlayerState.playing) {
        player.seek(Duration.zero).catchError((_) {});
      } else {
        player.resume().catchError((_) {});
      }
    }

    loading.then((ok) {
      if (ok && _isRunning && !_isPaused && _loadedKey[player] == key) go();
    });
  }

  void _scheduleNextBeat({bool immediate = false}) {
    if (!_isRunning || _isPaused) return;

    if (immediate) {
      _executeBeat();
      return;
    }

    // Interval to next beat based on current BPM
    final bpm = _currentBpm.clamp(10, 300);
    final intervalMs = (60000 / bpm).round();

    _beatTimer?.cancel();
    _beatTimer = Timer(Duration(milliseconds: intervalMs), () {
      if (!_isRunning || _isPaused) return;
      _executeBeat();
    });
  }

  void _executeBeat() {
    final now = DateTime.now();
    if (_lastBeatTime != null) {
      final delta = now.difference(_lastBeatTime!).inMilliseconds / 1000.0;
      _elapsedSeconds += delta;
      if (_totalDurationSeconds > 0 && _elapsedSeconds > _totalDurationSeconds) {
        _elapsedSeconds = _totalDurationSeconds.toDouble();
      }
    }
    _lastBeatTime = now;
    _beatCount++;

    // Calculate dynamic BPM and trend for current time
    _currentBpm = _config.calculateBpmAt(_elapsedSeconds, _totalDurationSeconds, seed: _seed);
    _trend = _config.calculateTrendAt(_elapsedSeconds, _totalDurationSeconds, seed: _seed);

    bool isShift = false;
    if (_config.mode == CadenceMode.random && _config.randomIntervalSeconds > 0) {
      final currentStep = (_elapsedSeconds / _config.randomIntervalSeconds).floor();
      if (_lastRandomStepIndex != -1 && currentStep != _lastRandomStepIndex) {
        isShift = true;
      }
      _lastRandomStepIndex = currentStep;
    }

    // Audio & Haptic feedback
    if (_config.enableAudio) {
      _playBeatAudio(isShift: isShift);
    }
    if (_config.enableHaptics) {
      _playHaptic(isShift: isShift);
    }

    final tick = CadenceTick(
      beatNumber: _beatCount,
      currentBpm: _currentBpm,
      progress: progress,
      elapsedSeconds: _elapsedSeconds,
      totalDurationSeconds: _totalDurationSeconds,
      mode: _config.mode,
      trend: _trend,
      isTempoShift: isShift,
    );

    // Connected novelty hardware sync
    if (_config.enableToy && _config.toyMode == CadenceToyMode.pulse) {
      ToyService.instance.onCadenceTick(tick);
    }

    _tickController.add(tick);
    onTickCallback?.call(tick);
    notifyListeners();

    // Check if finished session
    if (_totalDurationSeconds > 0 && _elapsedSeconds >= _totalDurationSeconds) {
      stop();
      return;
    }

    _scheduleNextBeat(immediate: false);
  }

  void _startContinuousToyLoop() {
    _continuousToyTimer?.cancel();
    if (!_config.enableToy || _config.toyMode != CadenceToyMode.continuous) return;

    _updateContinuousToy();
    _continuousToyTimer = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (!_isRunning || _isPaused) return;
      _updateContinuousToy();
    });
  }

  void _updateContinuousToy() {
    if (!ToyService.instance.isConnected) return;
    final speed = _config.calculateToySpeedAt(
      _elapsedSeconds,
      _totalDurationSeconds,
      seed: _seed,
      maxCeiling: ToyService.instance.effectiveIntensity,
    );
    ToyService.instance.setVibrateSpeed(speed);
  }

  void _playBeatAudio({bool isShift = false}) {
    try {
      if (isShift) {
        final p = _playerShift;
        if (p != null) _fire(p, 'shift', CadenceSoundGenerator.getShiftCueWav);
        return;
      }
      final player = _usePlayerA ? _playerA : _playerB;
      _usePlayerA = !_usePlayerA;
      final tone = _config.soundTone;
      if (player != null) _fire(player, tone, () => CadenceSoundGenerator.getWav(tone));
    } catch (_) {}
  }

  void _playHaptic({bool isShift = false}) {
    try {
      if (isShift) {
        HapticFeedback.mediumImpact().catchError((_) {});
      } else {
        HapticFeedback.selectionClick().catchError((_) {});
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _beatTimer?.cancel();
    _continuousToyTimer?.cancel();
    _tickController.close();
    try {
      _playerA?.dispose();
      _playerB?.dispose();
      _playerShift?.dispose();
    } catch (_) {}
    super.dispose();
  }
}
