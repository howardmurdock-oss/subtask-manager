import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/chastity_timer.dart';
import '../../services/chastity_timer_service.dart';
import '../../services/sync_service.dart';
import 'timer_detail_view.dart';
import 'timer_format.dart';

/// Asks the player about a timer sent while another is already running:
/// what it is, what they already have, and - if both would use a lock
/// combination - that one lock cannot be set to two codes.
Future<void> showTimerInviteDialog(BuildContext context, TimerInvite invite) async {
  final timers = Provider.of<ChastityTimerService>(context, listen: false);
  final sync = Provider.of<SyncService>(context, listen: false);
  final answer = await showDialog<bool>(
    context: context,
    builder: (ctx) => _InviteDialog(invite: invite, timers: timers),
  );
  if (answer == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  if (answer) {
    final view = await timers.acceptInvite(invite.id);
    if (!context.mounted) return;
    if (view == null) {
      messenger.showSnackBar(const SnackBar(content: Text("Couldn't reach the timer. Try again in a moment.")));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => TimerDetailView(timerId: invite.id)));
  } else {
    await timers.declineInvite(invite.id);
    await sync.declineTimer(invite);
    messenger.showSnackBar(SnackBar(
      content: Text('Declined. ${invite.partnerName ?? 'They'} will be told.'),
      behavior: SnackBarBehavior.floating,
    ));
  }
}

class _InviteDialog extends StatefulWidget {
  const _InviteDialog({required this.invite, required this.timers});
  final TimerInvite invite;
  final ChastityTimerService timers;

  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  ChastityTimerView? _view;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.timers.peekInvite(widget.invite).then((v) {
      if (mounted) setState(() => (_view = v, _loading = false));
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final from = widget.invite.partnerName ?? 'Your director';
    final running = widget.timers.runningAsPlayer().where((r) => r.id != widget.invite.id).toList();
    final names = running.map((r) => r.partnerName == null ? 'your own timer' : 'one from ${r.partnerName}').toSet();
    final view = _view;
    final clash = view != null &&
        view.config.combinationEnabled &&
        running.any((r) => widget.timers.viewOf(r.id)?.config.combinationEnabled ?? false);

    String? what;
    if (view != null) {
      final c = view.config;
      what = c.openEnded
          ? 'No end time: it runs until $from ends it.'
          : view.remaining == null
              ? 'How long it runs is hidden.'
              : 'It runs for ${formatSpan(view.remaining!)}.';
      if (c.rewardTokens != null) what = '$what Completing it earns ${c.rewardTokens} tokens.';
    }

    return AlertDialog(
      icon: const Icon(Icons.lock_clock_rounded, size: 36, color: Colors.pinkAccent),
      title: Text('$from wants to start a timer'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('You already have ${names.isEmpty ? 'a timer' : names.join(' and ')} running.'),
            const SizedBox(height: 10),
            if (_loading)
              const LinearProgressIndicator()
            else if (what != null)
              Text(what)
            else
              const Text("Couldn't load its details right now."),
            if (clash) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Both timers use a lock combination. One lock can only be set to one of them - '
                        'only accept if you have a separate lock for each.',
                        style: TextStyle(color: theme.colorScheme.onSurface),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Later')),
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Decline')),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(clash ? 'Accept anyway' : 'Accept'),
        ),
      ],
    );
  }
}
