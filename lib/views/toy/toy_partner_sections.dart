import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/partner_service.dart';
import '../../services/sync_service.dart';
import '../../services/toy/toy_remote.dart';
import '../../services/toy/toy_service.dart';
import 'toy_control_view.dart';

/// The live-control parts of the toy sheet: partners' toys you can control,
/// and which partners may control yours.
class ToyPartnerSections extends StatelessWidget {
  const ToyPartnerSections({super.key, this.host, this.toy});

  final ToyRemoteHost? host;
  final ToyService? toy;

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    final partnerService = context.watch<PartnerService>();
    final host = this.host ?? ToyRemoteHost.instance;
    final toy = this.toy ?? ToyService.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([host, toy]),
      builder: (context, _) {
        final theme = Theme.of(context);
        final partners = partnerService.unblockedContacts
            .where((c) => !c.isSelf && c.pairingCode.isNotEmpty)
            .toList();
        final online = sync.partnersWithToyOnline();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _heading(theme, "PARTNERS' TOYS"),
            if (online.isEmpty)
              _hint(theme, "When a partner connects a toy and allows you to control it, it shows here.")
            else
              for (final p in online)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: const Icon(Icons.favorite_rounded),
                    title: Text(p.displayName),
                    subtitle: Text(sync.partnerToy(p)?.toyName ?? 'Toy online'),
                    trailing: FilledButton(
                      key: Key('toy-control-${p.pairingCode}'),
                      onPressed: () => ToyControlView.openPartner(context, p),
                      child: const Text('Control'),
                    ),
                  ),
                ),
            const SizedBox(height: 16),
            _heading(theme, 'PARTNER CONTROL OF YOUR TOY'),
            if (host.controller != null)
              Card(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                child: ListTile(
                  leading: const Icon(Icons.sensors_rounded),
                  title: Text('${host.controller!.displayName} is in control'),
                  trailing: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                    onPressed: host.stopNow,
                    child: const Text('Stop'),
                  ),
                ),
              ),
            if (partners.isEmpty)
              _hint(theme, 'Pair with a partner first.')
            else ...[
              _hint(
                theme,
                toy.isConnected
                    ? 'Partners you allow can control your toy live while it is connected.'
                    : 'Partners you allow can control your toy live once it is connected.',
              ),
              for (final p in partners)
                SwitchListTile(
                  key: Key('toy-allow-${p.pairingCode}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text('Let ${p.displayName} control it'),
                  value: host.isAllowed(p),
                  onChanged: (v) => host.setAllowed(p, v),
                ),
              if (host.allowed.isNotEmpty) ...[
                Row(children: [
                  const Expanded(child: Text('Partners may go up to')),
                  Text('${host.cap}/20', style: const TextStyle(fontWeight: FontWeight.bold)),
                ]),
                Slider(
                  value: host.cap.toDouble(),
                  min: 1,
                  max: 20,
                  divisions: 19,
                  onChanged: (v) => host.setCap(v.round()),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Pause partner control'),
                  subtitle: const Text('Keeps everyone allowed, but nobody can control it until you turn this off.'),
                  value: host.paused,
                  onChanged: host.setPaused,
                ),
              ],
            ],
          ],
        );
      },
    );
  }

  Widget _heading(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.1,
            color: theme.colorScheme.primary,
          ),
        ),
      );

  Widget _hint(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withValues(alpha: 0.65)),
        ),
      );
}

/// Shown over the whole app while a partner controls your toy, so it is never
/// happening unseen - with Stop and Pause one tap away.
class ToyRemoteBanner extends StatelessWidget {
  const ToyRemoteBanner({super.key, required this.child, this.host});

  final Widget child;
  final ToyRemoteHost? host;

  @override
  Widget build(BuildContext context) {
    final host = this.host ?? ToyRemoteHost.instance;
    return Stack(
      children: [
        child,
        ListenableBuilder(
          listenable: host,
          builder: (context, _) {
            final c = host.controller;
            if (c == null) return const SizedBox.shrink();
            final theme = Theme.of(context);
            return Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: SafeArea(
                top: false,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Material(
                      key: const Key('toy-remote-banner'),
                      elevation: 6,
                      borderRadius: BorderRadius.circular(16),
                      color: theme.colorScheme.primaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                        child: Row(children: [
                          Icon(Icons.sensors_rounded, color: theme.colorScheme.onPrimaryContainer),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '${c.displayName} is controlling your toy',
                              style: TextStyle(
                                color: theme.colorScheme.onPrimaryContainer,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: () => host.setPaused(true),
                            child: const Text('Pause'),
                          ),
                          FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                            onPressed: host.stopNow,
                            child: const Text('Stop'),
                          ),
                        ]),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
