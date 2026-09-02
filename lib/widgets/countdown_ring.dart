import 'package:flutter/material.dart';

class CountdownRing extends StatelessWidget {
  final int remainingSeconds;
  final int totalDurationSeconds;
  final double progress; // 0.0 to 1.0
  final double size;
  final Color? color;

  const CountdownRing({
    super.key,
    required this.remainingSeconds,
    required this.totalDurationSeconds,
    required this.progress,
    this.size = 140,
    this.color,
  });

  String _formatTime(int seconds) {
    if (seconds <= 0) return '00:00';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) {
      return '${h}h ${m.toString().padLeft(2, '0')}m';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeColor = color ?? theme.colorScheme.primary;
    final isUrgent = remainingSeconds > 0 && remainingSeconds < 120; // under 2 mins

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Background track
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              value: 1.0,
              strokeWidth: 8,
              valueColor: AlwaysStoppedAnimation<Color>(
                theme.colorScheme.surface.withOpacity(0.5),
              ),
            ),
          ),
          // Active progress arc
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              value: 1.0 - progress,
              strokeWidth: 8,
              strokeCap: StrokeCap.round,
              valueColor: AlwaysStoppedAnimation<Color>(
                isUrgent ? theme.colorScheme.error : activeColor,
              ),
            ),
          ),
          // Time display
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _formatTime(remainingSeconds),
                style: TextStyle(
                  fontSize: size * 0.22,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                  color: isUrgent ? theme.colorScheme.error : theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'REMAINING',
                style: TextStyle(
                  fontSize: size * 0.08,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.5,
                  color: theme.colorScheme.onSurface.withOpacity(0.5),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
