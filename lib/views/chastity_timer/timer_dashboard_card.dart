import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/chastity_timer.dart';
import '../../services/chastity_timer_service.dart';
import 'timer_detail_view.dart';
import 'timer_format.dart';
import 'timer_hub_view.dart';

/// The Chastity Timer on a dashboard: the running timer's countdown, or a
/// way in to start one. A card rather than another tab: a phone does not
/// fit a seventh destination.
class TimerDashboardCard extends StatefulWidget {
  const TimerDashboardCard({super.key, required this.role});

  final TimerRole role;

  @override
  State<TimerDashboardCard> createState() => _TimerDashboardCardState();
}

class _TimerDashboardCardState extends State<TimerDashboardCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Redraw once a second for the countdown.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ChastityTimerService timers;
    try {
      timers = Provider.of<ChastityTimerService>(context);
    } catch (_) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final mine = timers.active(role: widget.role);
    // Nothing running: a timer that ended and has not been looked at yet
    // comes first - its combination is what the player is waiting for.
    final unseen = mine.isEmpty ? timers.finishedUnseen(role: widget.role) : const <TimerRecord>[];
    final record = mine.isNotEmpty ? mine.first : (unseen.isEmpty ? null : unseen.first);
    final view = record == null ? null : timers.viewOf(record.id);
    final finished = view != null && view.isOver;

    String headline;
    String detail;
    if (record != null && finished) {
      final released = view.status == TimerStatus.released;
      if (widget.role == TimerRole.player) {
        headline = released ? 'Timer released' : 'Timer finished';
        detail = view.config.combinationEnabled
            ? 'Your combination is ready. Tap to see it.'
            : "You're free. Tap to see how it went.";
      } else {
        headline = released ? 'Timer released' : 'Timer finished';
        detail = '${record.partnerName ?? 'Your player'}${view.endedByPlayerChoice ? ' ended their timer' : released && view.releasedBy == TimerRole.player ? ' used the emergency release' : "'s timer is over"}. Tap to see how it went.';
      }
    } else if (record == null) {
      headline = widget.role == TimerRole.player ? 'No timer running' : 'No timers running';
      detail = widget.role == TimerRole.player ? 'Start one, or wait for your director to.' : 'Start a timer for a partner.';
    } else if (view == null) {
      headline = 'Loading…';
      detail = record.partnerName ?? '';
    } else if (view.config.openEnded) {
      headline = formatCountdown(view.elapsed);
      detail = widget.role == TimerRole.director
          ? 'locked so far for ${record.partnerName ?? 'your player'} · no end time'
          : 'locked so far · no end time';
    } else if (view.remaining == null) {
      headline = 'Time hidden';
      detail = widget.role == TimerRole.player
          ? 'Your director has hidden the time left. Locked for ${formatSpan(view.elapsed)} so far.'
          : '';
    } else {
      headline = formatCountdown(view.remaining!);
      detail = widget.role == TimerRole.director
          ? 'left for ${record.partnerName ?? 'your player'}'
          : 'left on your timer';
    }
    if (!finished && mine.length > 1) detail = '$detail  ·  ${mine.length - 1} more';

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => record == null
              ? TimerHubView(role: widget.role)
              : mine.length > 1 && !finished
                  ? TimerHubView(role: widget.role)
                  : TimerDetailView(timerId: record.id),
        )),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: (finished ? Colors.greenAccent : Colors.pinkAccent).withValues(alpha: 0.15),
                child: Icon(
                  finished ? Icons.lock_open_rounded : Icons.lock_clock_rounded,
                  color: finished ? Colors.greenAccent[400] : Colors.pinkAccent,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'CHASTITY TIMER',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      headline,
                      style: TextStyle(
                        fontSize: record != null && !finished && (view?.remaining != null || (view?.config.openEnded ?? false)) ? 22 : 16,
                        fontWeight: FontWeight.bold,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (detail.isNotEmpty)
                      Text(
                        detail,
                        style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withValues(alpha: 0.65)),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}
