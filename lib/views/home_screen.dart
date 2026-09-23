import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/security/security_service.dart';
import '../models/partner_contact.dart';
import '../models/active_order.dart';
import '../models/order_item.dart';
import '../services/sync_service.dart';
import '../services/partner_service.dart';
import 'player/player_dashboard_view.dart';
import 'player/inventory_view.dart';
import 'player/rewards_shop_view.dart';
import 'director/director_dashboard_view.dart';
import 'director/pack_manager_view.dart';
import 'contacts/partners_and_chat_view.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/update_flow.dart';
import '../services/update_service.dart';
import '../services/windows_updater.dart';
import 'pairing/pairing_view.dart';
import 'settings/settings_view.dart';
import 'quests/quests_hub_view.dart';

enum AppRole { player, director }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  AppRole _currentRole = AppRole.player;
  int _playerIndex = 0;
  int _directorIndex = 0;

  /// A published version newer than this one, once the check has run.
  AppUpdate? _update;
  bool _isRequestDialogShowing = false;
  StreamSubscription<ActiveOrder>? _orderSubscription;
  Timer? _updateTimer;

  /// A download from an update that never finished installing.
  String? _unfinishedUpdate;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSavedRole();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final sync = Provider.of<SyncService>(context, listen: false);
      _orderSubscription = sync.onOrderReceived.listen((order) {
        if (!mounted) return;
        if (_currentRole != AppRole.player || _playerIndex != 0) {
          _showIncomingOrderDialog(order);
        }
      });
      // The banner is the only thing that tells a sideloaded build a newer one
      // exists. Nothing called this, so it never appeared for anyone: the
      // Settings page was the only way to find an update.
      //
      // Forced, because opening the app is the moment a user is most able to
      // act on an update, and the interval would otherwise swallow the launch
      // that happens to fall inside it - which is most of them, on the day a
      // release goes out.
      _checkForUpdate(force: true);
      _checkUnfinishedUpdate();

      // And again while it stays open. A desktop copy can sit running for
      // days, and would otherwise never ask a second time.
      _updateTimer = Timer.periodic(
        UpdateService.checkInterval,
        (_) => _checkForUpdate(),
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _updateTimer?.cancel();
    _orderSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadSavedRole() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('app_active_role');
      if (saved != null) {
        final role = AppRole.values.firstWhere(
          (e) => e.name == saved,
          orElse: () => AppRole.player,
        );
        if (mounted) {
          setState(() {
            _currentRole = role;
          });
          final sync = Provider.of<SyncService>(context, listen: false);
          sync.setAppRole(role == AppRole.player ? ConnectionRole.player : ConnectionRole.director);
        }
      } else {
        final sync = Provider.of<SyncService>(context, listen: false);
        sync.setAppRole(ConnectionRole.player);
      }
    } catch (_) {}
  }

  Future<void> _toggleRole() async {
    final newRole = _currentRole == AppRole.player ? AppRole.director : AppRole.player;
    setState(() {
      _currentRole = newRole;
      _playerIndex = 0;
      _directorIndex = 0;
    });
    try {
      final sync = Provider.of<SyncService>(context, listen: false);
      sync.setAppRole(newRole == AppRole.player ? ConnectionRole.player : ConnectionRole.director);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('app_active_role', newRole.name);
    } catch (_) {}
  }

  void _checkAndShowIncomingRequestDialog(PartnerService partnerSvc, SyncService sync) {
    if (partnerSvc.pendingRequests.isNotEmpty && !_isRequestDialogShowing && mounted) {
      // Purge any requests for contacts that already exist, are self, or are already handled
      partnerSvc.cleanExistingContactRequests(ownCode: sync.pairingCode, ownDeviceId: sync.deviceId);
      if (partnerSvc.pendingRequests.isEmpty) return;

      final req = partnerSvc.pendingRequests.first;
      if (partnerSvc.isRequestHandled(req.senderCode, req.sharedSecret) ||
          partnerSvc.isExistingContactOrSelf(req.senderId, req.senderCode, ownCode: sync.pairingCode, ownDeviceId: sync.deviceId)) {
        partnerSvc.removeIncomingRequest(req.senderId);
        partnerSvc.removeIncomingRequest(req.senderCode);
        return;
      }

      _isRequestDialogShowing = true;
      final nameCtrl = TextEditingController(text: req.senderName.isNotEmpty ? req.senderName : 'Partner');
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          final theme = Theme.of(ctx);
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                Icon(Icons.person_add_alt_1_rounded, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                const Text('Incoming Partner Request', style: TextStyle(fontSize: 18)),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${req.senderName.isNotEmpty ? req.senderName : "A partner"} wants to connect and sync with you.',
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceVariant.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text('Role: ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                            Text(
                              req.senderRole == PartnerRole.dominant ? 'Dominant / Director' : 'Submissive / Player',
                              style: TextStyle(
                                fontSize: 12,
                                color: req.senderRole == PartnerRole.dominant ? Colors.purpleAccent : theme.colorScheme.primary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Text('Pairing Code: ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                            Text(req.senderCode, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Partner Nickname / Alias',
                      hintText: 'e.g. Master Jack / Dan',
                      prefixIcon: Icon(Icons.badge_rounded, size: 20),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                onPressed: () async {
                  await partnerSvc.markRequestHandled(req.senderCode, req.sharedSecret);
                  await sync.declinePairingRequest(req);
                  if (context.mounted) Navigator.pop(ctx);
                  _isRequestDialogShowing = false;
                },
                child: const Text('Decline'),
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.check_rounded, size: 18),
                label: const Text('Accept & Pair'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
                ),
                onPressed: () async {
                  await partnerSvc.markRequestHandled(req.senderCode, req.sharedSecret);
                  final customName = nameCtrl.text.trim();
                  await sync.acceptPairingRequest(req, customName: customName.isNotEmpty ? customName : null);
                  if (context.mounted) Navigator.pop(ctx);
                  _isRequestDialogShowing = false;
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Connected with ${customName.isNotEmpty ? customName : req.senderName}!'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  }
                },
              ),
            ],
          );
        },
      ).then((_) {
        _isRequestDialogShowing = false;
      });
    }
  }

  void _showIncomingOrderDialog(ActiveOrder activeOrder) {
    showDialog(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final assigner = activeOrder.assignedByPartnerName != null && activeOrder.assignedByPartnerName!.isNotEmpty
            ? activeOrder.assignedByPartnerName!
            : 'Director';
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.bolt_rounded, color: theme.colorScheme.primary, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('New Directive Dispatched!', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    Text('Assigned by $assigner • ${ActiveOrder.formatAssignedTime(activeOrder.assignedAt)}', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.6))),
                  ],
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                activeOrder.order.title,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
              if (activeOrder.order.description.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  activeOrder.order.description,
                  style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withOpacity(0.8)),
                ),
              ],
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (activeOrder.order.rewardTokens > 0)
                    Chip(
                      avatar: const Icon(Icons.stars_rounded, size: 16, color: Colors.amberAccent),
                      label: Text('+${activeOrder.order.rewardTokens} Tokens', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                      backgroundColor: Colors.amber.withOpacity(0.15),
                    ),
                  if (activeOrder.order.actionDurationSeconds > 0)
                    Chip(
                      avatar: const Icon(Icons.timer_rounded, size: 16, color: Colors.cyanAccent),
                      label: Text('Action: ${OrderItem.formatSecondsHuman(activeOrder.order.actionDurationSeconds)}', style: const TextStyle(fontSize: 11)),
                      backgroundColor: Colors.cyan.withOpacity(0.15),
                    ),
                  if (activeOrder.order.durationMinutes > 0)
                    Chip(
                      avatar: const Icon(Icons.alarm_rounded, size: 16, color: Colors.redAccent),
                      label: Text('Deadline: ${OrderItem.formatMinutesHuman(activeOrder.order.durationMinutes)}', style: const TextStyle(fontSize: 11)),
                      backgroundColor: Colors.red.withOpacity(0.15),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Dismiss'),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.assignment_rounded, size: 18),
              label: const Text('View in Orders'),
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
              ),
              onPressed: () {
                Navigator.pop(ctx);
                // Switching the tab is not enough on its own: an open chat
                // conversation is a pushed route sitting on top of the shell,
                // so the Orders page changed underneath it and nothing
                // appeared to happen.
                Navigator.of(context).popUntil((route) => route.isFirst);
                setState(() {
                  _currentRole = AppRole.player;
                  _playerIndex = 0; // Switch to Orders tab!
                });
                final sync = Provider.of<SyncService>(context, listen: false);
                sync.setAppRole(ConnectionRole.player);
              },
            ),
          ],
        );
      },
    );
  }

  /// Icon for the combined Partners & Chat destination, badged with unread
  /// messages plus waiting pairing requests.
  Widget _peopleIcon(bool selected, int count) {
    final icon = Icon(selected ? Icons.forum_rounded : Icons.forum_outlined);
    if (count <= 0) return icon;
    return Badge.count(count: count, child: icon);
  }

  /// Nothing tells someone running a sideloaded build that a new one exists,
  /// so the app asks - once a day, quietly, and never on its own initiative
  /// beyond saying so.
  /// Coming back to the app is the same moment as opening it, as far as an
  /// update is concerned - and on a phone it is the only one that happens.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    final security = Provider.of<SecurityService>(context, listen: false);
    // The lock screen has a queue of its own to get through; a network call
    // behind it helps nobody.
    if (security.isPinRequired && !security.isUnlocked) return;
    _checkForUpdate(interval: UpdateService.resumeInterval);
  }

  Future<void> _checkForUpdate({bool force = false, Duration? interval}) async {
    final update = await UpdateService.check(force: force, interval: interval);
    if (update == null || !mounted) return;
    if (await UpdateService.isSkipped(update.version)) return;
    UpdateFlow.instance.offer(update);
    if (mounted) setState(() => _update = update);
  }

  /// An update that downloaded and then failed to install leaves its files
  /// beside the installation and says nothing. Saying so is the difference
  /// between "the update did nothing" and "the update could not be applied".
  Future<void> _checkUnfinishedUpdate() async {
    final leftover = await WindowsUpdater.unfinishedUpdate();
    if (leftover == null || !mounted) return;
    setState(() => _unfinishedUpdate = leftover);
  }

  Widget _buildUnfinishedUpdateBanner(BuildContext context, String path) {
    final theme = Theme.of(context);
    return MaterialBanner(
      backgroundColor: theme.colorScheme.errorContainer.withOpacity(0.4),
      leading: Icon(Icons.info_outline_rounded, color: theme.colorScheme.error),
      content: Text(
        'The last update downloaded but could not be installed. This copy is '
        'still version ${UpdateService.currentVersion}, and the download is '
        'still on disk.',
        style: theme.textTheme.bodyMedium,
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() => _unfinishedUpdate = null),
          child: const Text('Later'),
        ),
        FilledButton(
          onPressed: () async {
            await WindowsUpdater.discardUnfinished(path);
            if (mounted) setState(() => _unfinishedUpdate = null);
          },
          child: const Text('Delete download'),
        ),
      ],
    );
  }

  Widget _buildUpdateBanner(BuildContext context, AppUpdate update) {
    final theme = Theme.of(context);
    final flow = UpdateFlow.instance;

    // One line that says where things are, rather than a state the user has to
    // infer from which buttons happen to be showing.
    String status() {
      switch (flow.phase) {
        case UpdatePhase.downloading:
          final pct = flow.progress;
          return pct == null
              ? 'Downloading version ${update.version}...'
              : 'Downloading version ${update.version} - ${(pct * 100).round()}%';
        case UpdatePhase.readyToInstall:
        case UpdatePhase.installing:
          return flow.message ?? 'Installing version ${update.version}...';
        case UpdatePhase.permissionRequired:
        case UpdatePhase.failed:
          return flow.message ?? 'That did not work.';
        case UpdatePhase.offered:
        case UpdatePhase.dismissed:
          final size = update.sizeLabel;
          return 'Version ${update.version} is available'
              '${size != null ? ' ($size)' : ''}. You are on ${UpdateService.currentVersion}.';
      }
    }

    List<Widget> actions() {
      switch (flow.phase) {
        case UpdatePhase.downloading:
          return [
            TextButton(
              onPressed: () => flow.cancelDownload(),
              child: const Text('Cancel'),
            ),
          ];
        case UpdatePhase.permissionRequired:
          return [
            TextButton(onPressed: () => flow.dismiss(), child: const Text('Not now')),
            FilledButton(
              onPressed: () => flow.grantInstallPermission(),
              child: const Text('Allow'),
            ),
          ];
        case UpdatePhase.readyToInstall:
        case UpdatePhase.failed:
          return [
            TextButton(onPressed: () => flow.dismiss(), child: const Text('Close')),
            FilledButton(
              onPressed: () => flow.phase == UpdatePhase.readyToInstall
                  ? flow.install()
                  : flow.downloadAndInstall(),
              child: Text(flow.phase == UpdatePhase.readyToInstall ? 'Install' : 'Try again'),
            ),
          ];
        case UpdatePhase.installing:
          return const [];
        case UpdatePhase.offered:
        case UpdatePhase.dismissed:
          return [
            TextButton(onPressed: () => flow.skip(), child: const Text('Skip')),
            TextButton(onPressed: () => flow.dismiss(), child: const Text('Later')),
            FilledButton(
              onPressed: () async {
                if (flow.canInstallInApp) {
                  await flow.downloadAndInstall();
                  return;
                }
                // Everywhere else - and for any release we cannot verify -
                // the browser is as far as this goes.
                final target = update.downloadUrl ?? update.notesUrl;
                if (target == null) return;
                await launchUrl(Uri.parse(target), mode: LaunchMode.externalApplication);
                flow.dismiss();
              },
              child: Text(flow.canInstallInApp ? 'Update' : 'Download'),
            ),
          ];
      }
    }

    return MaterialBanner(
      backgroundColor: flow.phase == UpdatePhase.failed
          ? theme.colorScheme.errorContainer.withOpacity(0.5)
          : theme.colorScheme.primary.withOpacity(0.12),
      leading: Icon(
        flow.phase == UpdatePhase.failed
            ? Icons.error_outline_rounded
            : Icons.system_update_rounded,
        color: flow.phase == UpdatePhase.failed
            ? theme.colorScheme.error
            : theme.colorScheme.primary,
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(status(), style: const TextStyle(fontSize: 13)),
          if (flow.phase == UpdatePhase.downloading) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: flow.progress),
          ],
        ],
      ),
      actions: actions(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final security = Provider.of<SecurityService>(context);
    final sync = Provider.of<SyncService>(context);
    final partnerSvc = Provider.of<PartnerService>(context);
    final theme = Theme.of(context);
    final isDesktop = MediaQuery.of(context).size.width > 700;

    final pendingRequestsCount = partnerSvc.pendingRequests.length;
    if (pendingRequestsCount > 0 && !_isRequestDialogShowing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _checkAndShowIncomingRequestDialog(partnerSvc, sync);
      });
    }

    final playerTabs = [
      const PlayerDashboardView(),
      QuestsHubView(currentRole: _currentRole),
      const InventoryView(),
      const RewardsShopView(),
      const PartnersAndChatView(),
      // Stats moved into Settings: seven destinations did not fit a phone, and
      // the record is something you go and look at, not somewhere you work.
      const SettingsView(),
    ];

    final directorTabs = [
      const DirectorDashboardView(),
      QuestsHubView(currentRole: _currentRole),
      const PackManagerView(),
      // One destination, not two. A director had Partners and Chat while a
      // player had only Chat, which made the same subject look like different
      // features depending on the side you were on.
      const PartnersAndChatView(),
      const SettingsView(),
    ];

    final activeBody = _currentRole == AppRole.player
        ? (_playerIndex < playerTabs.length ? playerTabs[_playerIndex] : playerTabs[0])
        : (_directorIndex < directorTabs.length ? directorTabs[_directorIndex] : directorTabs[0]);

    final unreadCount = partnerSvc.totalUnreadCount;
    // One destination now covers both, so it carries both counts.
    final peopleBadge = unreadCount + pendingRequestsCount;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            InkWell(
              onTap: _toggleRole,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _currentRole == AppRole.player
                      ? theme.colorScheme.primary.withOpacity(0.18)
                      : Colors.purple.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _currentRole == AppRole.player
                        ? theme.colorScheme.primary
                        : Colors.purpleAccent,
                    width: 1.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _currentRole == AppRole.player
                          ? Icons.person_outline_rounded
                          : Icons.admin_panel_settings_outlined,
                      size: 16,
                      color: _currentRole == AppRole.player
                          ? theme.colorScheme.primary
                          : Colors.purpleAccent,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _currentRole == AppRole.player ? 'PLAYER' : 'DIRECTOR',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                        color: _currentRole == AppRole.player
                            ? theme.colorScheme.primary
                            : Colors.purpleAccent,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.swap_horiz_rounded,
                      size: 14,
                      color: _currentRole == AppRole.player
                          ? theme.colorScheme.primary
                          : Colors.purpleAccent,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final showFullTitle = constraints.maxWidth >= 200;
                  final titleText = _currentRole == AppRole.player
                      ? (showFullTitle ? 'Orders & Directives' : 'Directives')
                      : (showFullTitle ? 'Director Command Hub' : 'Command Hub');
                  return FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      titleText,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              sync.status == ConnectionStatus.connected
                  ? Icons.cloud_done_rounded
                  : sync.status == ConnectionStatus.connecting
                      ? Icons.cloud_sync_rounded
                      : Icons.cloud_off_rounded,
              color: sync.status == ConnectionStatus.connected
                  ? Colors.greenAccent[400]
                  : sync.status == ConnectionStatus.connecting
                      ? Colors.amber
                      : Colors.grey,
            ),
            tooltip: sync.statusMessage,
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PairingView()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.visibility_off_rounded, color: Colors.amber),
            tooltip: 'Emergency Disguise (Panic)',
            onPressed: () => security.triggerPanic(),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_unfinishedUpdate != null)
            _buildUnfinishedUpdateBanner(context, _unfinishedUpdate!),
          if (_update != null)
            ListenableBuilder(
              listenable: UpdateFlow.instance,
              builder: (context, _) =>
                  UpdateFlow.instance.phase == UpdatePhase.dismissed
                      ? const SizedBox.shrink()
                      : _buildUpdateBanner(context, _update!),
            ),
          Expanded(
            child: isDesktop
          ? Row(
              children: [
                // The rail is as tall as its destinations, and a short window
                // - or anything above it, like an update banner - pushes the
                // last ones out of sight with no way to reach them. Let it
                // scroll, while still filling the height when there is room.
                LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: constraints.maxHeight),
                      child: IntrinsicHeight(
                        child: NavigationRail(
                  selectedIndex: _currentRole == AppRole.player ? _playerIndex : _directorIndex,
                  onDestinationSelected: (idx) {
                    setState(() {
                      if (_currentRole == AppRole.player) {
                        _playerIndex = idx;
                      } else {
                        _directorIndex = idx;
                      }
                    });
                  },
                  labelType: NavigationRailLabelType.all,
                  destinations: _currentRole == AppRole.player
                      ? [
                          const NavigationRailDestination(
                            icon: Icon(Icons.dashboard_outlined),
                            selectedIcon: Icon(Icons.dashboard_rounded),
                            label: Text('Orders'),
                          ),
                          const NavigationRailDestination(
                            icon: Icon(Icons.auto_stories_outlined),
                            selectedIcon: Icon(Icons.auto_stories_rounded),
                            label: Text('Quests'),
                          ),
                          const NavigationRailDestination(
                            icon: Icon(Icons.inventory_2_outlined),
                            selectedIcon: Icon(Icons.inventory_2_rounded),
                            label: Text('Gear'),
                          ),
                          const NavigationRailDestination(
                            icon: Icon(Icons.shopping_bag_outlined),
                            selectedIcon: Icon(Icons.shopping_bag_rounded),
                            label: Text('Rewards'),
                          ),
                          NavigationRailDestination(
                            icon: _peopleIcon(false, peopleBadge),
                            selectedIcon: _peopleIcon(true, peopleBadge),
                            label: const Text('Contacts'),
                          ),
                          const NavigationRailDestination(
                            icon: Icon(Icons.tune_outlined),
                            selectedIcon: Icon(Icons.tune_rounded),
                            label: Text('Settings'),
                          ),
                        ]
                      : [
                          const NavigationRailDestination(
                            icon: Icon(Icons.admin_panel_settings_outlined),
                            selectedIcon: Icon(Icons.admin_panel_settings_rounded),
                            label: Text('Control'),
                          ),
                          const NavigationRailDestination(
                            icon: Icon(Icons.auto_stories_outlined),
                            selectedIcon: Icon(Icons.auto_stories_rounded),
                            label: Text('Quests'),
                          ),
                          const NavigationRailDestination(
                            icon: Icon(Icons.folder_copy_outlined),
                            selectedIcon: Icon(Icons.folder_copy_rounded),
                            label: Text('Packs'),
                          ),
                          NavigationRailDestination(
                            icon: _peopleIcon(false, peopleBadge),
                            selectedIcon: _peopleIcon(true, peopleBadge),
                            label: const Text('Contacts'),
                          ),
                          const NavigationRailDestination(
                            icon: Icon(Icons.tune_outlined),
                            selectedIcon: Icon(Icons.tune_rounded),
                            label: Text('Settings'),
                          ),
                        ],
                        ),
                      ),
                    ),
                  ),
                ),
                const VerticalDivider(thickness: 1, width: 1),
                Expanded(child: activeBody),
              ],
            )
                : activeBody,
          ),
        ],
      ),
      bottomNavigationBar: isDesktop
          ? null
          : NavigationBar(
              selectedIndex: _currentRole == AppRole.player ? _playerIndex : _directorIndex,
              onDestinationSelected: (idx) {
                setState(() {
                  if (_currentRole == AppRole.player) {
                    _playerIndex = idx;
                  } else {
                    _directorIndex = idx;
                  }
                });
              },
              destinations: _currentRole == AppRole.player
                  ? [
                      const NavigationDestination(
                        icon: Icon(Icons.dashboard_outlined),
                        selectedIcon: Icon(Icons.dashboard_rounded),
                        label: 'Orders',
                      ),
                      const NavigationDestination(
                        icon: Icon(Icons.auto_stories_outlined),
                        selectedIcon: Icon(Icons.auto_stories_rounded),
                        label: 'Quests',
                      ),
                      const NavigationDestination(
                        icon: Icon(Icons.inventory_2_outlined),
                        selectedIcon: Icon(Icons.inventory_2_rounded),
                        label: 'Gear',
                      ),
                      const NavigationDestination(
                        icon: Icon(Icons.shopping_bag_outlined),
                        selectedIcon: Icon(Icons.shopping_bag_rounded),
                        label: 'Rewards',
                      ),
                      NavigationDestination(
                        icon: _peopleIcon(false, peopleBadge),
                        selectedIcon: _peopleIcon(true, peopleBadge),
                        label: 'Contacts',
                      ),
                      const NavigationDestination(
                        icon: Icon(Icons.tune_outlined),
                        selectedIcon: Icon(Icons.tune_rounded),
                        label: 'Settings',
                      ),
                    ]
                  : [
                      const NavigationDestination(
                        icon: Icon(Icons.admin_panel_settings_outlined),
                        selectedIcon: Icon(Icons.admin_panel_settings_rounded),
                        label: 'Control',
                      ),
                      const NavigationDestination(
                        icon: Icon(Icons.auto_stories_outlined),
                        selectedIcon: Icon(Icons.auto_stories_rounded),
                        label: 'Quests',
                      ),
                      const NavigationDestination(
                        icon: Icon(Icons.folder_copy_outlined),
                        selectedIcon: Icon(Icons.folder_copy_rounded),
                        label: 'Packs',
                      ),
                      NavigationDestination(
                        icon: _peopleIcon(false, peopleBadge),
                        selectedIcon: _peopleIcon(true, peopleBadge),
                        label: 'Contacts',
                      ),
                      const NavigationDestination(
                        icon: Icon(Icons.tune_outlined),
                        selectedIcon: Icon(Icons.tune_rounded),
                        label: 'Settings',
                      ),
                    ],
            ),
    );
  }
}
