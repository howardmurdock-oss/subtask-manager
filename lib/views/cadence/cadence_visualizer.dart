import 'package:flutter/material.dart';
import '../../models/cadence_config.dart';
import '../../services/cadence_engine.dart';

/// Interactive pulsing visualizer ring and cadence status display.
class CadenceVisualizer extends StatefulWidget {
  final CadenceEngine engine;
  final double size;
  final bool compact;
  final VoidCallback? onTap;

  const CadenceVisualizer({
    super.key,
    required this.engine,
    this.size = 200,
    this.compact = false,
    this.onTap,
  });

  @override
  State<CadenceVisualizer> createState() => _CadenceVisualizerState();
}

class _CadenceVisualizerState extends State<CadenceVisualizer> with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _glowAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );

    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.12).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeOutQuad),
    );

    _glowAnimation = Tween<double>(begin: 0.15, end: 0.65).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeOutQuad),
    );

    widget.engine.ticks.listen((tick) {
      if (!mounted) return;
      _pulseController.forward(from: 0.0).then((_) {
        if (mounted) _pulseController.reverse();
      });
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Color _getModeColor(CadenceMode mode, ThemeData theme) {
    switch (mode) {
      case CadenceMode.fixed:
        return theme.colorScheme.primary;
      case CadenceMode.wave:
        return Colors.tealAccent[400] ?? Colors.teal;
      case CadenceMode.peak:
        return Colors.amberAccent[400] ?? Colors.amber;
      case CadenceMode.ramp:
        return Colors.deepOrangeAccent;
      case CadenceMode.random:
        return Colors.purpleAccent;
      case CadenceMode.none:
        return Colors.grey;
    }
  }

  String _formatMode(CadenceMode mode) {
    switch (mode) {
      case CadenceMode.fixed:
        return 'FIXED BPM';
      case CadenceMode.wave:
        return 'WAVE';
      case CadenceMode.peak:
        return 'PEAK';
      case CadenceMode.ramp:
        return 'RAMP';
      case CadenceMode.random:
        return 'RANDOM';
      case CadenceMode.none:
        return 'DISABLED';
    }
  }

  Widget _buildTrendIndicator(TempoTrend trend, Color color) {
    switch (trend) {
      case TempoTrend.accelerating:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.arrow_upward_rounded, size: 14, color: Colors.greenAccent),
            const SizedBox(width: 2),
            Text(
              'Accelerating',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.greenAccent[400]),
            ),
          ],
        );
      case TempoTrend.decelerating:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.arrow_downward_rounded, size: 14, color: Colors.amberAccent),
            const SizedBox(width: 2),
            Text(
              'Slowing',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.amberAccent[400]),
            ),
          ],
        );
      case TempoTrend.steady:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.drag_handle_rounded, size: 14, color: color.withOpacity(0.7)),
            const SizedBox(width: 2),
            Text(
              'Steady',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color.withOpacity(0.7)),
            ),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final engine = widget.engine;
    final modeColor = _getModeColor(engine.config.mode, theme);

    if (widget.compact) {
      return AnimatedBuilder(
        animation: _pulseController,
        builder: (context, child) {
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: modeColor.withOpacity(0.08 + _glowAnimation.value * 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: modeColor.withOpacity(0.3 + _glowAnimation.value * 0.4),
                    width: 1.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Transform.scale(
                      scale: _scaleAnimation.value,
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: modeColor,
                          boxShadow: [
                            BoxShadow(
                              color: modeColor.withOpacity(_glowAnimation.value),
                              blurRadius: 10,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${engine.currentBpm}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'BPM',
                      style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.6)),
                    ),
                    const SizedBox(width: 10),
                    _buildTrendIndicator(engine.trend, modeColor),
                    const Spacer(),
                    IconButton(
                      icon: Icon(
                        engine.config.enableAudio ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                        size: 18,
                      ),
                      tooltip: engine.config.enableAudio ? 'Mute Sound' : 'Enable Sound',
                      onPressed: () => engine.toggleAudio(!engine.config.enableAudio),
                    ),
                    IconButton(
                      icon: Icon(
                        engine.config.enableHaptics ? Icons.vibration_rounded : Icons.smartphone_rounded,
                        size: 18,
                      ),
                      tooltip: engine.config.enableHaptics ? 'Disable Haptics' : 'Enable Haptics',
                      onPressed: () => engine.toggleHaptics(!engine.config.enableHaptics),
                    ),
                    if (widget.onTap != null) ...[
                      const SizedBox(width: 2),
                      Tooltip(
                        message: 'Expand Metronome',
                        child: Icon(
                          Icons.fullscreen_rounded,
                          size: 22,
                          color: modeColor.withOpacity(0.9),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Pulsing Ring
        AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) {
            return Transform.scale(
              scale: _scaleAnimation.value,
              child: Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: modeColor.withOpacity(0.06 + _glowAnimation.value * 0.1),
                  border: Border.all(
                    color: modeColor.withOpacity(0.35 + _glowAnimation.value * 0.45),
                    width: 4,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: modeColor.withOpacity(_glowAnimation.value * 0.8),
                      blurRadius: 36,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(
                          color: modeColor.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          _formatMode(engine.config.mode),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.1,
                            color: modeColor,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${engine.currentBpm}',
                        style: TextStyle(
                          fontSize: widget.size * 0.28,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -1,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      Text(
                        'BEATS PER MINUTE',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.2,
                          color: theme.colorScheme.onSurface.withOpacity(0.6),
                        ),
                      ),
                      const SizedBox(height: 6),
                      _buildTrendIndicator(engine.trend, modeColor),
                    ],
                  ),
                ),
              ),
            );
          },
        ),

        const SizedBox(height: 16),

        // Beat count & progress
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.graphic_eq_rounded, size: 16, color: modeColor),
            const SizedBox(width: 6),
            Text(
              'Beat #${engine.beatCount}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            if (engine.totalDurationSeconds > 0) ...[
              const SizedBox(width: 14),
              Text(
                '${engine.elapsedSeconds.toStringAsFixed(1)}s / ${engine.totalDurationSeconds}s',
                style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurface.withOpacity(0.65),
                ),
              ),
            ],
          ],
        ),

        if (engine.totalDurationSeconds > 0) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: engine.progress,
                minHeight: 6,
                backgroundColor: theme.colorScheme.surface.withOpacity(0.4),
                valueColor: AlwaysStoppedAnimation<Color>(modeColor),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
