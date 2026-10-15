import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/active_order.dart';
import '../../models/cadence_config.dart';
import '../../services/cadence_engine.dart';
import '../../services/order_engine.dart';
import 'cadence_visualizer.dart';

/// Full-screen immersive pulse view for the metronome during action routine execution.
class MetronomeFullScreenView extends StatefulWidget {
  final CadenceEngine engine;
  final ActiveOrder activeOrder;

  const MetronomeFullScreenView({
    super.key,
    required this.engine,
    required this.activeOrder,
  });

  @override
  State<MetronomeFullScreenView> createState() => _MetronomeFullScreenViewState();
}

class _MetronomeFullScreenViewState extends State<MetronomeFullScreenView> {
  @override
  void initState() {
    super.initState();
    widget.engine.addListener(_onEngineUpdate);
  }

  @override
  void dispose() {
    widget.engine.removeListener(_onEngineUpdate);
    super.dispose();
  }

  void _onEngineUpdate() {
    if (mounted) setState(() {});
  }

  String _formatSeconds(int totalSeconds) {
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final engine = widget.engine;
    final screenSize = MediaQuery.of(context).size;
    final visualizerSize = min(screenSize.width * 0.72, 280.0);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_fullscreen_rounded),
          tooltip: 'Exit Full Screen',
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.activeOrder.order.title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              'Metronome: ${engine.config.mode.displayName}',
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: engine.config.enableAudio ? 'Mute Sound' : 'Enable Sound',
            icon: Icon(engine.config.enableAudio ? Icons.volume_up_rounded : Icons.volume_off_rounded),
            onPressed: () => engine.toggleAudio(!engine.config.enableAudio),
          ),
          IconButton(
            tooltip: engine.config.enableHaptics ? 'Disable Haptics' : 'Enable Haptics',
            icon: Icon(engine.config.enableHaptics ? Icons.vibration_rounded : Icons.smartphone_rounded),
            onPressed: () => engine.toggleHaptics(!engine.config.enableHaptics),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Top pulse visualizer (matching the top of the studio)
                CadenceVisualizer(
                  engine: engine,
                  size: visualizerSize,
                  compact: false,
                ),

                const SizedBox(height: 28),

                // Order countdown timer and routine state
                Consumer<OrderEngine>(
                  builder: (context, orderEngine, _) {
                    final liveOrder = orderEngine.activeOrders
                        .cast<ActiveOrder?>()
                        .firstWhere(
                          (o) => o?.id == widget.activeOrder.id,
                          orElse: () => widget.activeOrder,
                        );

                    final isRunning = liveOrder?.isActionTimerRunning ?? false;
                    final isFinished = liveOrder?.isActionTimerFinished ?? false;
                    final secs = liveOrder?.currentActionSecondsRemaining ?? 0;

                    return Column(
                      children: [
                        Text(
                          _formatSeconds(secs),
                          style: TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 2,
                            color: isFinished
                                ? Colors.greenAccent[400]
                                : (isRunning
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurface),
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          isFinished
                              ? 'Action complete! Alarm sounded.'
                              : (isRunning
                                  ? 'Routine timer in progress'
                                  : 'Routine timer paused'),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: isFinished
                                ? Colors.greenAccent[400]
                                : theme.colorScheme.onSurface.withOpacity(0.65),
                          ),
                        ),
                        const SizedBox(height: 18),
                        if (!isFinished)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (isRunning)
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.pause_rounded, size: 20),
                                  label: const Text('Pause Routine'),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                  ),
                                  onPressed: () => orderEngine.pauseActionTimer(widget.activeOrder.id),
                                )
                              else
                                ElevatedButton.icon(
                                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                                  label: const Text('Resume Routine'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: theme.colorScheme.primary,
                                    foregroundColor: theme.colorScheme.brightness == Brightness.dark
                                        ? Colors.black
                                        : Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                  ),
                                  onPressed: () => orderEngine.startActionTimer(widget.activeOrder.id),
                                ),
                            ],
                          ),
                      ],
                    );
                  },
                ),

                const SizedBox(height: 24),

                // Exit Full Screen button
                TextButton.icon(
                  icon: const Icon(Icons.close_fullscreen_rounded, size: 16),
                  label: const Text('Exit Full Screen', style: TextStyle(fontSize: 12)),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
