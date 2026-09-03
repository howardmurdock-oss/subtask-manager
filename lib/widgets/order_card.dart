import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/active_order.dart';
import '../models/order_item.dart';
import '../services/order_engine.dart';
import 'countdown_ring.dart';

class OrderCard extends StatelessWidget {
  final ActiveOrder activeOrder;
  final VoidCallback? onComplete;
  final VoidCallback? onSubmitProof;
  final VoidCallback? onForfeit;
  final VoidCallback? onDismiss;

  const OrderCard({
    super.key,
    required this.activeOrder,
    this.onComplete,
    this.onSubmitProof,
    this.onForfeit,
    this.onDismiss,
  });

  Color _getTierColor(int tier, BuildContext context) {
    switch (tier) {
      case 1:
        return const Color(0xFF10B981); // Emerald
      case 2:
        return const Color(0xFF38BDF8); // Sky
      case 3:
        return const Color(0xFFFBBF24); // Amber
      case 4:
        return const Color(0xFFF97316); // Orange
      case 5:
      default:
        return const Color(0xFFEF4444); // Red
    }
  }

  String _formatDuration(OrderItem order) {
    switch (order.durationType) {
      case DurationType.instant:
        return 'Instant';
      case DurationType.actionTimer:
        return '${OrderItem.formatSecondsHuman(order.actionDurationSeconds)} Routine Timer';
      case DurationType.deadlineCountdown:
        return '${OrderItem.formatMinutesHuman(order.durationMinutes)} Deadline';
      case DurationType.actionWithDeadline:
        final actStr = OrderItem.formatSecondsHuman(order.actionDurationSeconds);
        final deadStr = OrderItem.formatMinutesHuman(order.durationMinutes);
        return '$actStr Timer ($deadStr Deadline)';
      case DurationType.dailyWindow:
        return 'Today';
    }
  }

  String _formatSeconds(int totalSeconds) {
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final engine = Provider.of<OrderEngine>(context, listen: false);
    final theme = Theme.of(context);
    final order = activeOrder.order;
    final tierColor = _getTierColor(order.tier, context);

    final hasActionTimer = (order.durationType == DurationType.actionTimer ||
            order.durationType == DurationType.actionWithDeadline) &&
        order.actionDurationSeconds > 0;

    final hasDeadline = (order.durationType == DurationType.deadlineCountdown ||
            order.durationType == DurationType.actionWithDeadline) &&
        order.durationMinutes > 0;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top badges row
            Row(
              children: [
                // Category badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    order.category.toUpperCase(),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Tier badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: tierColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: tierColor.withOpacity(0.4)),
                  ),
                  child: Text(
                    'TIER ${order.tier}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: tierColor,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Duration info
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.schedule_rounded, size: 12, color: theme.colorScheme.onSurface.withOpacity(0.7)),
                      const SizedBox(width: 4),
                      Text(
                        _formatDuration(order),
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurface.withOpacity(0.7),
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                if (activeOrder.assignedByDirector)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.purple.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.purpleAccent.withOpacity(0.5)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.lock_person_rounded, size: 12, color: Colors.purpleAccent),
                        const SizedBox(width: 4),
                        Text(
                          activeOrder.assignedByPartnerName != null && activeOrder.assignedByPartnerName!.isNotEmpty
                              ? activeOrder.assignedByPartnerName!.toUpperCase()
                              : 'DIRECTOR',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.purpleAccent,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // Main body & Deadline Countdown ring (if deadline exists)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        order.title,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        order.description,
                        style: TextStyle(
                          fontSize: 14,
                          color: theme.colorScheme.onSurface.withOpacity(0.8),
                          height: 1.35,
                        ),
                      ),
                      if (order.requiredEquipment.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Icon(Icons.inventory_2_outlined, size: 14, color: Colors.cyanAccent),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Required Gear: ${order.requiredEquipment.join(", ")}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.cyanAccent,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(
                            Icons.schedule_rounded,
                            size: 13,
                            color: theme.colorScheme.onSurface.withOpacity(0.55),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Assigned: ${ActiveOrder.formatAssignedTime(activeOrder.assignedAt)}',
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onSurface.withOpacity(0.6),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (hasDeadline && activeOrder.status == OrderStatus.active) ...[
                  const SizedBox(width: 16),
                  CountdownRing(
                    remainingSeconds: activeOrder.remainingSeconds,
                    totalDurationSeconds: order.durationMinutes * 60,
                    progress: activeOrder.deadlineProgressPercentage,
                    size: 84,
                  ),
                ],
              ],
            ),

            // Interactive Action / Routine Timer Card (if task has an action duration)
            if (hasActionTimer && activeOrder.status == OrderStatus.active) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: activeOrder.isActionTimerFinished
                      ? Colors.greenAccent.withOpacity(0.12)
                      : (activeOrder.isActionTimerRunning
                          ? theme.colorScheme.primary.withOpacity(0.12)
                          : theme.colorScheme.surface.withOpacity(0.7)),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: activeOrder.isActionTimerFinished
                        ? Colors.greenAccent.withOpacity(0.5)
                        : (activeOrder.isActionTimerRunning
                            ? theme.colorScheme.primary.withOpacity(0.5)
                            : theme.colorScheme.onSurface.withOpacity(0.15)),
                  ),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: activeOrder.isActionTimerFinished
                          ? Colors.greenAccent.withOpacity(0.2)
                          : theme.colorScheme.primary.withOpacity(0.2),
                      child: Icon(
                        activeOrder.isActionTimerFinished
                            ? Icons.alarm_on_rounded
                            : (activeOrder.isActionTimerRunning
                                ? Icons.timer_rounded
                                : Icons.play_arrow_rounded),
                        color: activeOrder.isActionTimerFinished
                            ? Colors.greenAccent[400]
                            : theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _formatSeconds(activeOrder.currentActionSecondsRemaining),
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.5,
                              color: activeOrder.isActionTimerFinished
                                  ? Colors.greenAccent[400]
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                          Text(
                            activeOrder.isActionTimerFinished
                                ? 'Action complete! Alarm sounded.'
                                : (activeOrder.isActionTimerRunning
                                    ? 'Routine in progress...'
                                    : 'Get in position & start timer'),
                            style: TextStyle(
                              fontSize: 11,
                              color: activeOrder.isActionTimerFinished
                                  ? Colors.greenAccent[400]
                                  : theme.colorScheme.onSurface.withOpacity(0.6),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!activeOrder.isActionTimerFinished) ...[
                      if (!activeOrder.isActionTimerRunning)
                        ElevatedButton.icon(
                          onPressed: () => engine.startActionTimer(activeOrder.id),
                          icon: const Icon(Icons.play_arrow_rounded, size: 16),
                          label: const Text('Start'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: theme.colorScheme.primary,
                            foregroundColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
                          ),
                        )
                      else
                        OutlinedButton.icon(
                          onPressed: () => engine.pauseActionTimer(activeOrder.id),
                          icon: const Icon(Icons.pause_rounded, size: 16),
                          label: const Text('Pause'),
                        ),
                    ] else ...[
                      IconButton(
                        tooltip: 'Restart Action Timer',
                        icon: const Icon(Icons.replay_rounded, size: 20),
                        onPressed: () => engine.resetActionTimer(activeOrder.id),
                      ),
                    ],
                  ],
                ),
              ),
            ],

            const SizedBox(height: 14),

            // Token stakes
            Row(
              children: [
                Icon(Icons.add_circle_outline_rounded, size: 14, color: Colors.greenAccent[400]),
                const SizedBox(width: 4),
                Text(
                  '+${order.rewardTokens} Tokens',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.greenAccent[400],
                  ),
                ),
                const SizedBox(width: 14),
                Icon(Icons.remove_circle_outline_rounded, size: 14, color: Colors.redAccent[200]),
                const SizedBox(width: 4),
                Text(
                  '-${order.penaltyTokens} Tokens if failed',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.redAccent[200],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 12),

            // Action buttons
            Row(
              children: [
                if (onDismiss != null)
                  IconButton(
                    tooltip: 'Dismiss / Clear Task',
                    icon: Icon(Icons.delete_outline_rounded, size: 18, color: theme.colorScheme.onSurface.withOpacity(0.4)),
                    onPressed: onDismiss,
                  ),
                const Spacer(),
                if (onForfeit != null && activeOrder.status == OrderStatus.active)
                  TextButton.icon(
                    onPressed: onForfeit,
                    icon: const Icon(Icons.close_rounded, size: 16),
                    label: const Text('Forfeit'),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                  ),
                const SizedBox(width: 8),
                if (order.verificationType == VerificationType.noteProof ||
                    order.verificationType == VerificationType.photoProof ||
                    activeOrder.assignedByDirector)
                  ElevatedButton.icon(
                    onPressed: onSubmitProof,
                    icon: const Icon(Icons.edit_note_rounded, size: 18),
                    label: const Text('Submit Proof'),
                  )
                else
                  ElevatedButton.icon(
                    onPressed: onComplete,
                    icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
                    label: const Text('Complete Task'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
