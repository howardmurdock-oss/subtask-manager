import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../services/order_engine.dart';

class StatsView extends StatelessWidget {
  const StatsView({super.key});

  @override
  Widget build(BuildContext context) {
    final engine = Provider.of<OrderEngine>(context);
    final stats = engine.stats;
    final history = stats.history;
    final theme = Theme.of(context);
    final dateFormat = DateFormat('MMM d, h:mm a');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Performance & History'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 1. Score Hero Card
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Text(
                    'DISCIPLINE SCORE',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 130,
                        height: 130,
                        child: CircularProgressIndicator(
                          value: stats.disciplineScore / 100,
                          strokeWidth: 10,
                          strokeCap: StrokeCap.round,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            stats.disciplineScore >= 70
                                ? Colors.greenAccent[400]!
                                : stats.disciplineScore >= 40
                                    ? Colors.amber
                                    : Colors.redAccent,
                          ),
                          backgroundColor: theme.colorScheme.surface.withOpacity(0.5),
                        ),
                      ),
                      Column(
                        children: [
                          Text(
                            '${stats.disciplineScore}',
                            style: const TextStyle(
                              fontSize: 36,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            'out of 100',
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onSurface.withOpacity(0.5),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    stats.disciplineScore >= 80
                        ? 'Exemplary Compliance'
                        : stats.disciplineScore >= 50
                            ? 'Steady Progress'
                            : 'Requires Improvement',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),

          // 2. Metrics Grid
          Row(
            children: [
              Expanded(
                child: _buildMetricCard(
                  context,
                  title: 'CURRENT STREAK',
                  value: '${stats.currentStreakDays} Days',
                  sub: 'Best: ${stats.bestStreakDays} Days',
                  icon: Icons.local_fire_department_rounded,
                  iconColor: Colors.amber,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildMetricCard(
                  context,
                  title: 'COMPLIANCE',
                  value: '${stats.complianceRate.toStringAsFixed(1)}%',
                  sub: '${stats.totalCompleted} done / ${stats.totalFailed} failed',
                  icon: Icons.pie_chart_outline_rounded,
                  iconColor: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          Row(
            children: [
              Expanded(
                child: _buildMetricCard(
                  context,
                  title: 'TOKEN BALANCE',
                  value: '${stats.tokens}',
                  sub: 'Available credit',
                  icon: Icons.toll_rounded,
                  iconColor: Colors.greenAccent[400]!,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildMetricCard(
                  context,
                  title: 'TOTAL TASKS',
                  value: '${stats.totalCompleted + stats.totalFailed}',
                  sub: 'Lifetime assignments',
                  icon: Icons.assignment_turned_in_rounded,
                  iconColor: Colors.purpleAccent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // 3. History Log Section
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'ACTIVITY & DISCIPLINE LOG',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  color: theme.colorScheme.primary,
                ),
              ),
              Text(
                '${history.length} events',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurface.withOpacity(0.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          if (history.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
                child: Column(
                  children: [
                    Icon(
                      Icons.history_toggle_off_rounded,
                      size: 48,
                      color: theme.colorScheme.onSurface.withOpacity(0.3),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'No logged activity events yet',
                      style: TextStyle(
                        fontSize: 14,
                        color: theme.colorScheme.onSurface.withOpacity(0.6),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            ...history.map((entry) {
              final isSuccess = entry.isSuccess;

              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: isSuccess
                        ? Colors.greenAccent.withOpacity(0.15)
                        : Colors.redAccent.withOpacity(0.15),
                    child: Icon(
                      isSuccess ? Icons.check_circle_outline : Icons.highlight_off,
                      color: isSuccess ? Colors.greenAccent[400] : Colors.redAccent,
                    ),
                  ),
                  title: Text(
                    entry.orderTitle,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 2),
                      Text(
                        '${entry.category} • Tier ${entry.tier} • ${entry.reason}',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface.withOpacity(0.7),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        dateFormat.format(entry.timestamp),
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurface.withOpacity(0.4),
                        ),
                      ),
                    ],
                  ),
                  trailing: Text(
                    entry.tokenDelta >= 0 ? '+${entry.tokenDelta}' : '${entry.tokenDelta}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: entry.tokenDelta >= 0 ? Colors.greenAccent[400] : Colors.redAccent,
                    ),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildMetricCard(
    BuildContext context, {
    required String title,
    required String value,
    required String sub,
    required IconData icon,
    required Color iconColor,
  }) {
    final theme = Theme.of(context);
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: iconColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.0,
                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              value,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              sub,
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
