import 'package:flutter/material.dart';

import '../../core/community_links.dart';
import 'public_timer_view.dart';

/// The Chastity Timer, until it comes to everyone on October 14: what it
/// does, where to get it now, and - already here - the timers this app is
/// watching from other people's public links.
class ChastityTimerTeaserCard extends StatelessWidget {
  const ChastityTimerTeaserCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withValues(alpha: 0.7));
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              CircleAvatar(
                backgroundColor: Colors.pinkAccent.withValues(alpha: 0.15),
                child: const Icon(Icons.lock_clock_rounded, color: Colors.pinkAccent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('CHASTITY TIMER',
                      style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.2, color: theme.colorScheme.primary)),
                  const Text('On Patreon now · for everyone from October 14',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                ]),
              ),
              const Icon(Icons.lock_rounded, size: 18),
            ]),
            const SizedBox(height: 8),
            Text(
              'Run a timer with a public link people can vote on and send orders to. '
              "Watching other people's timers works here already: open their link and choose \"Open in the app\".",
              style: muted,
            ),
            Wrap(spacing: 4, children: [
              TextButton.icon(
                icon: const Icon(Icons.notifications_active_rounded, size: 18),
                label: const Text('Watching'),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WatchingView())),
              ),
              TextButton.icon(
                icon: const Icon(Icons.favorite_rounded, size: 18),
                label: const Text('Get it on Patreon'),
                onPressed: () => CommunityLinks.open(CommunityLinks.patreon),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
