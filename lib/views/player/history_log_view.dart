import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../services/order_engine.dart';

class HistoryLogView extends StatelessWidget {
  const HistoryLogView({super.key});

  @override
  Widget build(BuildContext context) {
    final engine = Provider.of<OrderEngine>(context);
    final history = engine.stats.history;
    final theme = Theme.of(context);
    final dateFormat = DateFormat('MMM d, h:mm a');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Discipline History Log'),
      ),
      body: history.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.history_toggle_off_rounded,
                    size: 64,
                    color: theme.colorScheme.onSurface.withOpacity(0.3),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'No logged events yet',
                    style: TextStyle(
                      fontSize: 16,
                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: history.length,
              itemBuilder: (context, index) {
                final entry = history[index];
                final isSuccess = entry.isSuccess;

                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 6),
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
                      style: const TextStyle(fontWeight: FontWeight.bold),
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
                        fontSize: 16,
                        color: entry.tokenDelta >= 0 ? Colors.greenAccent[400] : Colors.redAccent,
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
