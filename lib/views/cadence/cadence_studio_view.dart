import 'dart:math';
import 'package:flutter/material.dart';
import '../../models/cadence_config.dart';
import '../../services/cadence_engine.dart';
import 'cadence_visualizer.dart';

/// Interactive Cadence & Pacing Metronome Studio (Test Tool)
class CadenceStudioView extends StatefulWidget {
  final CadenceConfig? initialConfig;
  final int? initialDuration;

  const CadenceStudioView({
    super.key,
    this.initialConfig,
    this.initialDuration,
  });

  @override
  State<CadenceStudioView> createState() => _CadenceStudioViewState();
}

class _CadenceStudioViewState extends State<CadenceStudioView> {
  late CadenceEngine _engine;

  CadenceMode _selectedMode = CadenceMode.fixed;
  int _fixedBpm = 60;
  int _minBpm = 30;
  int _maxBpm = 110;
  int _durationSeconds = 60;
  int _waveCount = 2;
  int _randomIntervalSeconds = 15;
  CadenceSoundTone _selectedTone = CadenceSoundTone.woodblock;
  bool _enableAudio = true;
  bool _enableHaptics = true;

  @override
  void initState() {
    super.initState();
    final cfg = widget.initialConfig ?? const CadenceConfig();
    _selectedMode = cfg.mode == CadenceMode.none ? CadenceMode.fixed : cfg.mode;
    _fixedBpm = cfg.bpm;
    _minBpm = cfg.minBpm;
    _maxBpm = cfg.maxBpm;
    _waveCount = cfg.waveCount;
    _randomIntervalSeconds = cfg.randomIntervalSeconds;
    _selectedTone = cfg.soundTone;
    _enableAudio = cfg.enableAudio;
    _enableHaptics = cfg.enableHaptics;
    _durationSeconds = widget.initialDuration ?? 60;

    _engine = CadenceEngine(
      config: _buildCurrentConfig(),
      totalDurationSeconds: _durationSeconds,
    );
  }

  @override
  void dispose() {
    _engine.dispose();
    super.dispose();
  }

  CadenceConfig _buildCurrentConfig() {
    return CadenceConfig(
      mode: _selectedMode,
      bpm: _fixedBpm,
      minBpm: _minBpm,
      maxBpm: _maxBpm,
      waveCount: _waveCount,
      randomIntervalSeconds: _randomIntervalSeconds,
      soundTone: _selectedTone,
      enableAudio: _enableAudio,
      enableHaptics: _enableHaptics,
      enableVisual: true,
    );
  }

  void _applyConfigToEngine() {
    _engine.setTotalDuration(_durationSeconds);
    _engine.updateConfig(_buildCurrentConfig());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Metronome Studio'),
        actions: [
          IconButton(
            tooltip: _enableAudio ? 'Mute Sound' : 'Enable Sound',
            icon: Icon(_enableAudio ? Icons.volume_up_rounded : Icons.volume_off_rounded),
            onPressed: () {
              setState(() => _enableAudio = !_enableAudio);
              _applyConfigToEngine();
            },
          ),
          IconButton(
            tooltip: _enableHaptics ? 'Disable Haptics' : 'Enable Haptics',
            icon: Icon(_enableHaptics ? Icons.vibration_rounded : Icons.smartphone_rounded),
            onPressed: () {
              setState(() => _enableHaptics = !_enableHaptics);
              _applyConfigToEngine();
            },
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: _engine,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            children: [
              // Center Visualizer Ring
              Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
                  child: Center(
                    child: CadenceVisualizer(
                      engine: _engine,
                      size: 210,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Transport Control Bar (Start / Pause / Reset)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (!_engine.isRunning)
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
                      ),
                      icon: const Icon(Icons.play_arrow_rounded, size: 24),
                      label: const Text('Start Cadence', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      onPressed: () {
                        _applyConfigToEngine();
                        _engine.start();
                      },
                    )
                  else if (_engine.isPaused)
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                        backgroundColor: Colors.greenAccent[400],
                        foregroundColor: Colors.black,
                      ),
                      icon: const Icon(Icons.play_arrow_rounded, size: 24),
                      label: const Text('Resume', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      onPressed: () => _engine.resume(),
                    )
                  else
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                        backgroundColor: Colors.amberAccent[700],
                        foregroundColor: Colors.black,
                      ),
                      icon: const Icon(Icons.pause_rounded, size: 24),
                      label: const Text('Pause', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      onPressed: () => _engine.pause(),
                    ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                    ),
                    icon: const Icon(Icons.replay_rounded, size: 20),
                    label: const Text('Reset'),
                    onPressed: () => _engine.reset(),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // Mode Selection Section
              Text(
                'METRONOME MODE',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _modeChip(CadenceMode.fixed, 'Fixed BPM', Icons.straighten_rounded),
                  _modeChip(CadenceMode.wave, 'Wave', Icons.waves_rounded),
                  _modeChip(CadenceMode.peak, 'Peak', Icons.landscape_rounded),
                  _modeChip(CadenceMode.ramp, 'Ramp', Icons.trending_up_rounded),
                  _modeChip(CadenceMode.random, 'Random', Icons.shuffle_rounded),
                ],
              ),

              const SizedBox(height: 20),

              // Curve Preview Graph
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.show_chart_rounded, size: 16, color: theme.colorScheme.primary),
                          const SizedBox(width: 6),
                          const Text(
                            'Tempo Progression Curve',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                          const Spacer(),
                          Text(
                            _selectedMode == CadenceMode.fixed
                                ? '$_fixedBpm BPM'
                                : '$_minBpm ➔ $_maxBpm BPM',
                            style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.6)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 60,
                        width: double.infinity,
                        child: CustomPaint(
                          painter: _CadenceCurvePainter(
                            config: _buildCurrentConfig(),
                            durationSeconds: _durationSeconds,
                            currentProgress: _engine.progress,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // Parameters Section
              Text(
                'METRONOME PARAMETERS',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 8),

              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Column(
                    children: [
                      if (_selectedMode == CadenceMode.fixed) ...[
                        _sliderTile(
                          title: 'Target BPM',
                          valueText: '$_fixedBpm BPM',
                          value: _fixedBpm.toDouble(),
                          min: 20,
                          max: 240,
                          onChanged: (val) {
                            setState(() => _fixedBpm = val.round());
                            _applyConfigToEngine();
                          },
                        ),
                      ] else ...[
                        _sliderTile(
                          title: 'Minimum BPM (Start / Base)',
                          valueText: '$_minBpm BPM',
                          value: _minBpm.toDouble(),
                          min: 15,
                          max: 180,
                          onChanged: (val) {
                            setState(() {
                              _minBpm = val.round();
                              if (_minBpm >= _maxBpm) _maxBpm = _minBpm + 10;
                            });
                            _applyConfigToEngine();
                          },
                        ),
                        const Divider(),
                        _sliderTile(
                          title: 'Maximum BPM (Peak / Target)',
                          valueText: '$_maxBpm BPM',
                          value: _maxBpm.toDouble(),
                          min: 25,
                          max: 240,
                          onChanged: (val) {
                            setState(() {
                              _maxBpm = val.round();
                              if (_maxBpm <= _minBpm) _minBpm = max(10, _maxBpm - 10);
                            });
                            _applyConfigToEngine();
                          },
                        ),
                      ],

                      const Divider(),

                      // Duration slider
                      _sliderTile(
                        title: 'Total Routine Duration',
                        valueText: _formatDuration(_durationSeconds),
                        value: _durationSeconds.toDouble(),
                        min: 15,
                        max: 600,
                        divisions: 39,
                        onChanged: (val) {
                          setState(() => _durationSeconds = val.round());
                          _applyConfigToEngine();
                        },
                      ),

                      if (_selectedMode == CadenceMode.wave) ...[
                        const Divider(),
                        _sliderTile(
                          title: 'Wave Swell Cycles',
                          valueText: '$_waveCount ${_waveCount == 1 ? "wave" : "waves"}',
                          value: _waveCount.toDouble(),
                          min: 1,
                          max: 6,
                          divisions: 5,
                          onChanged: (val) {
                            setState(() => _waveCount = val.round());
                            _applyConfigToEngine();
                          },
                        ),
                      ],

                      if (_selectedMode == CadenceMode.random) ...[
                        const Divider(),
                        _sliderTile(
                          title: 'Surprise Shift Interval',
                          valueText: 'Every $_randomIntervalSeconds seconds',
                          value: _randomIntervalSeconds.toDouble(),
                          min: 5,
                          max: 45,
                          divisions: 8,
                          onChanged: (val) {
                            setState(() => _randomIntervalSeconds = val.round());
                            _applyConfigToEngine();
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // Sound Tone Selection
              Text(
                'SOUND & HAPTICS',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 8),

              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.music_note_rounded, size: 20),
                          const SizedBox(width: 12),
                          const Text('Tone Synthesis:', style: TextStyle(fontWeight: FontWeight.w600)),
                          const Spacer(),
                          DropdownButton<CadenceSoundTone>(
                            value: _selectedTone,
                            underline: const SizedBox.shrink(),
                            items: const [
                              DropdownMenuItem(value: CadenceSoundTone.woodblock, child: Text('Woodblock')),
                              DropdownMenuItem(value: CadenceSoundTone.tick, child: Text('Mechanical Tick')),
                              DropdownMenuItem(value: CadenceSoundTone.beep, child: Text('Acoustic Beep')),
                              DropdownMenuItem(value: CadenceSoundTone.bass, child: Text('Sub Bass Pulse')),
                              DropdownMenuItem(value: CadenceSoundTone.bell, child: Text('Crystal Bell')),
                            ],
                            onChanged: (val) {
                              if (val != null) {
                                setState(() => _selectedTone = val);
                                _applyConfigToEngine();
                              }
                            },
                          ),
                        ],
                      ),
                      const Divider(),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Audio Beat Clicks'),
                        subtitle: const Text('Synthesizes audible clicks on each beat.'),
                        value: _enableAudio,
                        onChanged: (val) {
                          setState(() => _enableAudio = val);
                          _applyConfigToEngine();
                        },
                      ),
                      const Divider(),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Haptic Vibration Pulse'),
                        subtitle: const Text('Tactile vibration pulse on mobile devices.'),
                        value: _enableHaptics,
                        onChanged: (val) {
                          setState(() => _enableHaptics = val);
                          _applyConfigToEngine();
                        },
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }

  Widget _modeChip(CadenceMode mode, String label, IconData icon) {
    final theme = Theme.of(context);
    final isSelected = _selectedMode == mode;

    return ChoiceChip(
      selected: isSelected,
      avatar: Icon(icon, size: 16, color: isSelected ? theme.colorScheme.onPrimary : null),
      label: Text(label),
      onSelected: (selected) {
        if (selected) {
          setState(() => _selectedMode = mode);
          _applyConfigToEngine();
        }
      },
    );
  }

  Widget _sliderTile({
    required String title,
    required String valueText,
    required double value,
    required double min,
    required double max,
    int? divisions,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            Text(valueText, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }

  String _formatDuration(int seconds) {
    if (seconds < 60) return '$seconds seconds';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return s > 0 ? '$m min $s sec' : '$m minutes';
  }
}

/// Custom painter for the live cadence curve preview
class _CadenceCurvePainter extends CustomPainter {
  final CadenceConfig config;
  final int durationSeconds;
  final double currentProgress;
  final Color color;

  _CadenceCurvePainter({
    required this.config,
    required this.durationSeconds,
    required this.currentProgress,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paintLine = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    final paintFill = Paint()
      ..color = color.withOpacity(0.12)
      ..style = PaintingStyle.fill;

    final low = min(config.minBpm, config.maxBpm).toDouble();
    final high = max(config.minBpm, config.maxBpm).toDouble();
    final bpmRange = high == low ? 1.0 : (high - low);

    final path = Path();
    const pointsCount = 80;

    for (int i = 0; i <= pointsCount; i++) {
      final tRatio = i / pointsCount;
      final t = tRatio * durationSeconds;
      final bpm = config.calculateBpmAt(t, durationSeconds);
      final normalized = ((bpm - low) / bpmRange).clamp(0.0, 1.0);

      // Invert Y: higher BPM = higher up (lower Y coordinate)
      final x = tRatio * size.width;
      final y = size.height - (normalized * (size.height - 8) + 4);

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final fillPath = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    canvas.drawPath(fillPath, paintFill);
    canvas.drawPath(path, paintLine);

    // Draw active progress cursor if playing
    if (currentProgress > 0.0) {
      final cursorX = currentProgress * size.width;
      final cursorPaint = Paint()
        ..color = Colors.white
        ..strokeWidth = 2.0;
      canvas.drawLine(Offset(cursorX, 0), Offset(cursorX, size.height), cursorPaint);

      final circlePaint = Paint()..color = color;
      canvas.drawCircle(Offset(cursorX, size.height / 2), 4, circlePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _CadenceCurvePainter oldDelegate) {
    return oldDelegate.config != config ||
        oldDelegate.durationSeconds != durationSeconds ||
        oldDelegate.currentProgress != currentProgress;
  }
}
