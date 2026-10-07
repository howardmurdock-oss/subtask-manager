import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/chastity_timer.dart';
import '../../services/chastity_timer_service.dart';
import 'timer_detail_view.dart';
import 'timer_format.dart';
import 'timer_setup_view.dart';
import 'timer_invite.dart';
import 'timer_profile_view.dart';

/// Every timer this device can reach on one side, running first, and the
/// way to start a new one.
class TimerHubView extends StatefulWidget {
  const TimerHubView({super.key, required this.role});

  final TimerRole role;

  @override
  State<TimerHubView> createState() => _TimerHubViewState();
}

class _TimerHubViewState extends State<TimerHubView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<ChastityTimerService>(context, listen: false).refreshAll();
    });
  }

  @override
  Widget build(BuildContext context) {
    final timers = Provider.of<ChastityTimerService>(context);
    final theme = Theme.of(context);
    final records = timers.records.where((r) => r.role == widget.role).toList()
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    bool over(TimerRecord r) => (timers.viewOf(r.id)?.isOver ?? false) || timers.isLost(r.id);
    final running = records.where((r) => !over(r)).toList();
    final finished = records.where(over).toList();

    Widget tile(TimerRecord r) {
      final view = timers.viewOf(r.id);
      final String subtitle;
      if (timers.isLost(r.id)) {
        subtitle = 'No longer reachable from this device';
      } else if (view == null) {
        subtitle = 'Not reachable right now';
      } else if (view.status == TimerStatus.released) {
        final how = view.endedByPlayerChoice
            ? 'Ended'
            : view.releasedBy == TimerRole.player
                ? 'Emergency release'
                : view.config.openEnded
                    ? 'Ended'
                    : 'Ended early';
        subtitle = timers.wasDeclined(r.id) ? 'Declined' : '$how · ran for ${formatSpan(view.elapsed)}';
      } else if (view.isOver) {
        subtitle = 'Finished · ran for ${formatSpan(view.elapsed)}';
      } else if (view.config.openEnded) {
        subtitle = 'Locked for ${formatSpan(view.elapsed)} · no end time';
      } else if (view.remaining == null) {
        subtitle = 'Time hidden · locked for ${formatSpan(view.elapsed)}';
      } else {
        subtitle = '${formatCountdown(view.remaining!)} left';
      }
      final who = r.partnerName == null
          ? 'Your own timer'
          : widget.role == TimerRole.director
              ? 'For ${r.partnerName}'
              : 'With ${r.partnerName}';
      return Card(
        child: ListTile(
          leading: Icon(
            view?.isOver ?? false ? Icons.lock_open_rounded : Icons.lock_clock_rounded,
            color: view?.isOver ?? false ? theme.colorScheme.onSurface.withValues(alpha: 0.5) : Colors.pinkAccent,
          ),
          title: Text(who, style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => TimerDetailView(timerId: r.id)),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Chastity Timer')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add_rounded),
        label: Text(widget.role == TimerRole.player ? 'Start my timer' : 'Start a timer'),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => TimerSetupView(role: widget.role)),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: timers.refreshAll,
        child: ListView(
          // Room for the button, and for the system navigation bar: Android
          // draws the app behind it.
          padding: EdgeInsets.fromLTRB(16, 12, 16, 96 + MediaQuery.paddingOf(context).bottom),
          children: [
            if (records.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Column(
                  children: [
                    Icon(Icons.lock_clock_rounded, size: 56, color: theme.colorScheme.primary.withValues(alpha: 0.6)),
                    const SizedBox(height: 12),
                    Text(
                      widget.role == TimerRole.player
                          ? 'No timers yet. Start your own, or your director can start one for you.'
                          : 'No timers yet. Start one for a partner whose app has the Chastity Timer.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            if (widget.role == TimerRole.player)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.public_rounded, color: Colors.cyan),
                  title: const Text('Your public page', style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(timers.profile == null
                      ? 'One link that always shows your current timer.'
                      : timers.profileLink!),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const TimerProfileView()),
                  ),
                ),
              ),
            if (widget.role == TimerRole.player) const SizedBox(height: 12),
            if (widget.role == TimerRole.player && timers.invites.isNotEmpty) ...[
              _heading('REQUESTS', theme),
              ...timers.invites.map((i) => Card(
                    child: ListTile(
                      leading: const Icon(Icons.mark_email_unread_rounded, color: Colors.pinkAccent),
                      title: Text('${i.partnerName ?? 'Your director'} wants to start a timer',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: const Text('Tap to accept or decline.'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => showTimerInviteDialog(context, i),
                    ),
                  )),
              const SizedBox(height: 12),
            ],
            if (running.isNotEmpty) ...[
              _heading('RUNNING', theme),
              ...running.map(tile),
            ],
            if (finished.isNotEmpty) ...[
              const SizedBox(height: 12),
              _heading('FINISHED', theme),
              ...finished.map(tile),
            ],
          ],
        ),
      ),
    );
  }

  Widget _heading(String text, ThemeData theme) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
            color: theme.colorScheme.primary,
          ),
        ),
      );
}
