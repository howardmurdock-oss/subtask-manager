import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/partner_service.dart';
import '../../services/sync_service.dart';
import '../../services/toy/toy_models.dart';
import '../../services/toy/toy_remote.dart';
import '../../services/toy/toy_service.dart';
import 'toy_control_view.dart';
import 'toy_manager_sheet.dart';

/// Your own toy on the player's main screen: connect it, control it, and see
/// whether a partner is steering it, without going into Settings. Hidden for
/// anyone who has never connected a toy.
class YourToyDashboardCard extends StatelessWidget {
  const YourToyDashboardCard({super.key, this.host, this.toy});

  final ToyRemoteHost? host;
  final ToyService? toy;

  @override
  Widget build(BuildContext context) {
    final host = this.host ?? ToyRemoteHost.instance;
    final toy = this.toy ?? ToyService.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([host, toy]),
      builder: (context, _) {
        final connected = toy.isConnected;
        final connecting = toy.state == ToyConnectionState.connecting;
        final name = toy.connectedToy?.name ?? toy.rememberedToyName;
        if (name == null) return const SizedBox.shrink();

        final theme = Theme.of(context);
        final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
        final controller = host.controller;
        final battery = toy.connectedToy?.batteryLevel ?? -1;

        final String status;
        if (connecting) {
          status = 'Connecting…';
        } else if (!connected) {
          status = 'Not connected';
        } else if (controller != null) {
          status = '${controller.displayName} is in control';
        } else if (host.allowed.isEmpty) {
          status = 'Only you can control it';
        } else if (host.paused) {
          status = 'Partner control paused';
        } else {
          final names = (context.read<PartnerService?>()?.unblockedContacts ?? const [])
              .where(host.isAllowed)
              .map((c) => c.displayName)
              .toList();
          status = names.isEmpty ? 'Partners can control it' : 'Partners can control it: ${names.join(', ')}';
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Card(
            key: const Key('dashboard-your-toy'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Icon(
                      connected ? Icons.bluetooth_connected_rounded : Icons.bluetooth_disabled_rounded,
                      color: connected ? theme.colorScheme.primary : muted,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'YOUR TOY',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          Text(
                            name,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            status,
                            key: const Key('dashboard-your-toy-status'),
                            style: TextStyle(fontSize: 12, color: muted),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    if (connected && battery >= 0)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text('$battery%', style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    IconButton(
                      key: const Key('dashboard-your-toy-settings'),
                      tooltip: 'Toy settings',
                      icon: const Icon(Icons.tune_rounded),
                      onPressed: () => ToyManagerSheet.show(context),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Row(children: [
                      if (connected) ...[
                        Expanded(
                          child: FilledButton.icon(
                            key: const Key('dashboard-your-toy-control'),
                            onPressed: () => ToyControlView.openLocal(context),
                            icon: const Icon(Icons.tune_rounded, size: 18),
                            label: const Text('Control'),
                          ),
                        ),
                        if (controller != null) ...[
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton.icon(
                              key: const Key('dashboard-your-toy-stop'),
                              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                              onPressed: host.stopNow,
                              icon: const Icon(Icons.stop_rounded, size: 18),
                              label: const Text('Stop'),
                            ),
                          ),
                        ],
                      ] else
                        Expanded(
                          child: OutlinedButton.icon(
                            key: const Key('dashboard-your-toy-connect'),
                            onPressed: connecting ? null : toy.reconnectRemembered,
                            icon: const Icon(Icons.bluetooth_searching_rounded, size: 18),
                            label: Text(connecting ? 'Connecting…' : 'Connect'),
                          ),
                        ),
                    ]),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Partners' toys on the director's main screen, so controlling one is a
/// tap away rather than inside the toy settings. Hidden until a partner has
/// shared a toy with you.
class PartnerToysDashboardCard extends StatelessWidget {
  const PartnerToysDashboardCard({super.key});

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    context.watch<PartnerService>();
    final shared = sync.partnersWithToyShared();
    if (shared.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Card(
        key: const Key('dashboard-partner-toys'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Icon(Icons.favorite_rounded, color: theme.colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                const Text("PARTNERS' TOYS", style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.1)),
              ]),
              const SizedBox(height: 4),
              for (final p in shared)
                Builder(builder: (context) {
                  final status = sync.partnerToy(p);
                  final online = status?.isOnline ?? false;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      online ? Icons.bluetooth_connected_rounded : Icons.bluetooth_disabled_rounded,
                      color: online ? theme.colorScheme.primary : muted,
                    ),
                    title: Text(p.displayName, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      online ? (status?.toyName ?? 'Toy connected') : 'Toy not connected right now',
                      style: online ? null : TextStyle(color: muted),
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: online
                        ? FilledButton(
                            key: Key('dashboard-toy-${p.pairingCode}'),
                            onPressed: () => ToyControlView.openPartner(context, p),
                            child: const Text('Control'),
                          )
                        : null,
                  );
                }),
            ],
          ),
        ),
      ),
    );
  }
}

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
        final partners = partnerService.unblockedContacts.where((c) => !c.isSelf && c.pairingCode.isNotEmpty).toList();
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
