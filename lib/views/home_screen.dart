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
import 'player/stats_view.dart';
import 'player/inventory_view.dart';
import 'player/rewards_shop_view.dart';
import 'director/director_dashboard_view.dart';
import 'director/pack_manager_view.dart';
import 'contacts/partner_directory_view.dart';
import 'messenger/messenger_inbox_view.dart';
import 'pairing/pairing_view.dart';
import 'settings/settings_view.dart';
import 'quests/quests_hub_view.dart';

enum AppRole { player, director }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppRole _currentRole = AppRole.player;
  int _playerIndex = 0;
  int _directorIndex = 0;
  bool _isRequestDialogShowing = false;
  StreamSubscription<ActiveOrder>? _orderSubscription;

  @override
  void initState() {
    super.initState();
    _loadSavedRole();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final sync = Provider.of<SyncService>(context, listen: false);
      _orderSubscription = sync.onOrderReceived.listen((order) {
        if (!mounted) return;
        if (_currentRole != AppRole.player || _playerIndex != 0) {
          _showIncomingOrderDialog(order);
        }
      });
    });
  }

  @override
  void dispose() {
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
      // Purge any requests for contacts that already exist or are self
      partnerSvc.cleanExistingContactRequests(ownCode: sync.pairingCode, ownDeviceId: sync.deviceId);
      if (partnerSvc.pendingRequests.isEmpty) return;

      _isRequestDialogShowing = true;
      final req = partnerSvc.pendingRequests.first;
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
                onPressed: () {
                  sync.declinePairingRequest(req);
                  Navigator.pop(ctx);
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
                  final customName = nameCtrl.text.trim();
                  await sync.acceptPairingRequest(req, customName: customName.isNotEmpty ? customName : null);
                  Navigator.pop(ctx);
                  _isRequestDialogShowing = false;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Connected with ${customName.isNotEmpty ? customName : req.senderName}!'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
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
                    Text('Assigned by $assigner', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.6))),
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
      const MessengerInboxView(),
      const StatsView(),
      const SettingsView(),
    ];

    final directorTabs = [
      const DirectorDashboardView(),
      QuestsHubView(currentRole: _currentRole),
      const PackManagerView(),
      const PartnerDirectoryView(),
      const MessengerInboxView(),
      const SettingsView(),
    ];

    final activeBody = _currentRole == AppRole.player
        ? (_playerIndex < playerTabs.length ? playerTabs[_playerIndex] : playerTabs[0])
        : (_directorIndex < directorTabs.length ? directorTabs[_directorIndex] : directorTabs[0]);

    final unreadCount = partnerSvc.totalUnreadCount;

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
              child: Text(
                _currentRole == AppRole.player ? 'Orders & Directives' : 'Director Command Hub',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
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
      body: isDesktop
          ? Row(
              children: [
                NavigationRail(
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
                            icon: unreadCount > 0
                                ? Badge.count(count: unreadCount, child: const Icon(Icons.forum_outlined))
                                : const Icon(Icons.forum_outlined),
                            selectedIcon: unreadCount > 0
                                ? Badge.count(count: unreadCount, child: const Icon(Icons.forum_rounded))
                                : const Icon(Icons.forum_rounded),
                            label: const Text('Chat'),
                          ),
                          const NavigationRailDestination(
                            icon: Icon(Icons.bar_chart_outlined),
                            selectedIcon: Icon(Icons.bar_chart_rounded),
                            label: Text('Stats'),
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
                            icon: pendingRequestsCount > 0
                                ? Badge.count(
                                    count: pendingRequestsCount,
                                    backgroundColor: Colors.amber,
                                    textColor: Colors.black,
                                    child: const Icon(Icons.group_outlined),
                                  )
                                : const Icon(Icons.group_outlined),
                            selectedIcon: pendingRequestsCount > 0
                                ? Badge.count(
                                    count: pendingRequestsCount,
                                    backgroundColor: Colors.amber,
                                    textColor: Colors.black,
                                    child: const Icon(Icons.group_rounded),
                                  )
                                : const Icon(Icons.group_rounded),
                            label: const Text('Partners'),
                          ),
                          NavigationRailDestination(
                            icon: unreadCount > 0
                                ? Badge.count(count: unreadCount, child: const Icon(Icons.forum_outlined))
                                : const Icon(Icons.forum_outlined),
                            selectedIcon: unreadCount > 0
                                ? Badge.count(count: unreadCount, child: const Icon(Icons.forum_rounded))
                                : const Icon(Icons.forum_rounded),
                            label: const Text('Chat'),
                          ),
                          const NavigationRailDestination(
                            icon: Icon(Icons.tune_outlined),
                            selectedIcon: Icon(Icons.tune_rounded),
                            label: Text('Settings'),
                          ),
                        ],
                ),
                const VerticalDivider(thickness: 1, width: 1),
                Expanded(child: activeBody),
              ],
            )
          : activeBody,
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
                        icon: unreadCount > 0
                            ? Badge.count(count: unreadCount, child: const Icon(Icons.forum_outlined))
                            : const Icon(Icons.forum_outlined),
                        selectedIcon: unreadCount > 0
                            ? Badge.count(count: unreadCount, child: const Icon(Icons.forum_rounded))
                            : const Icon(Icons.forum_rounded),
                        label: 'Chat',
                      ),
                      const NavigationDestination(
                        icon: Icon(Icons.bar_chart_outlined),
                        selectedIcon: Icon(Icons.bar_chart_rounded),
                        label: 'Stats',
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
                        icon: pendingRequestsCount > 0
                            ? Badge.count(
                                count: pendingRequestsCount,
                                backgroundColor: Colors.amber,
                                textColor: Colors.black,
                                child: const Icon(Icons.group_outlined),
                              )
                            : const Icon(Icons.group_outlined),
                        selectedIcon: pendingRequestsCount > 0
                            ? Badge.count(
                                count: pendingRequestsCount,
                                backgroundColor: Colors.amber,
                                textColor: Colors.black,
                                child: const Icon(Icons.group_rounded),
                              )
                            : const Icon(Icons.group_rounded),
                        label: 'Partners',
                      ),
                      NavigationDestination(
                        icon: unreadCount > 0
                            ? Badge.count(count: unreadCount, child: const Icon(Icons.forum_outlined))
                            : const Icon(Icons.forum_outlined),
                        selectedIcon: unreadCount > 0
                            ? Badge.count(count: unreadCount, child: const Icon(Icons.forum_rounded))
                            : const Icon(Icons.forum_rounded),
                        label: 'Chat',
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
