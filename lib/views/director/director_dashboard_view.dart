import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/sync_service.dart';
import '../../services/order_engine.dart';
import '../../models/order_item.dart';
import '../../models/active_order.dart';
import '../../models/active_redemption.dart';
import '../../models/partner_contact.dart';
import '../../services/partner_service.dart';
import '../messenger/chat_conversation_view.dart';
import '../contacts/partner_directory_view.dart';
import 'order_dispatch_dialog.dart';
import 'reward_manager_view.dart';
import '../scheduling/schedule_order_dialog.dart';
import '../../services/quest_service.dart';
import '../../models/quest_item.dart';

class DirectorDashboardView extends StatelessWidget {
  const DirectorDashboardView({super.key});

  void _showExpandedImageDialog(BuildContext context, String base64Image, String title) {
    showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Proof: $title',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: Container(
                  color: Colors.black,
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 4.0,
                    child: Image.memory(
                      base64Decode(base64Image),
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
                ),
                child: const Text(
                  'Tip: Pinch or scroll to zoom in/out to inspect details.',
                  style: TextStyle(fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showDispatchDialog(BuildContext context, {OrderItem? initialOrder}) {
    OrderDispatchDialog.show(context, initialOrder: initialOrder);
  }

  void _showTokenAdjustmentDialog(BuildContext context) {
    final sync = Provider.of<SyncService>(context, listen: false);
    final engine = Provider.of<OrderEngine>(context, listen: false);
    final amountController = TextEditingController();
    final reasonController = TextEditingController();
    bool isPositive = true;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Adjust Player Tokens'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: ChoiceChip(
                          label: const Text('+ Reward'),
                          selected: isPositive,
                          selectedColor: Colors.greenAccent.withOpacity(0.2),
                          onSelected: (val) {
                            if (val) setDialogState(() => isPositive = true);
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ChoiceChip(
                          label: const Text('- Penalty'),
                          selected: !isPositive,
                          selectedColor: Colors.redAccent.withOpacity(0.2),
                          onSelected: (val) {
                            if (val) setDialogState(() => isPositive = false);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Token Quantity',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: amountController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      hintText: 'e.g. 50',
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Audit Reason / Justification',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: reasonController,
                    decoration: const InputDecoration(
                      hintText: 'e.g. Completed room cleanse drill',
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    final rawAmt = int.tryParse(amountController.text.trim()) ?? 0;
                    if (rawAmt <= 0) return;
                    final delta = isPositive ? rawAmt : -rawAmt;
                    final reason = reasonController.text.trim().isEmpty
                        ? (isPositive ? 'Director bonus' : 'Director penalty deduction')
                        : reasonController.text.trim();

                    sync.adjustPlayerTokens(delta, reason);
                    engine.adjustTokens(delta, reason);

                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Tokens adjusted by $delta ("$reason")'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                  child: const Text('Apply Token Delta'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showRejectProofDialog(
    BuildContext context,
    ActiveOrder active,
    SyncService sync,
    OrderEngine engine,
  ) {
    final noteController = TextEditingController();
    final theme = Theme.of(context);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.assignment_return_rounded, color: Colors.orangeAccent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Reject Proof: ${active.order.title}',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Select whether to return this directive back to the submissive\'s active queue to retry, or penalize them and terminate the task:',
                style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withOpacity(0.85)),
              ),
              const SizedBox(height: 14),
              Text(
                'Director Feedback / Reason (Optional)',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface.withOpacity(0.7),
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: noteController,
                maxLines: 2,
                decoration: const InputDecoration(
                  hintText: 'e.g. Angle unclear, incomplete duration, or incorrect form',
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orangeAccent.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orangeAccent.withOpacity(0.3)),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.replay_rounded, size: 16, color: Colors.orangeAccent),
                        SizedBox(width: 6),
                        Text(
                          'Reject & Return to Queue',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.orangeAccent),
                        ),
                      ],
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Puts directive back in submissive\'s Active Directives queue to attempt again. No token penalty deducted.',
                      style: TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.cancel_outlined, size: 16, color: Colors.redAccent),
                        const SizedBox(width: 6),
                        Text(
                          'Reject & Penalize (-${active.order.penaltyTokens} Tokens)',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.redAccent),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Terminates directive immediately, records failed status, and deducts penalty tokens.',
                      style: TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.replay_rounded, size: 16),
            label: const Text('Reject & Return'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.orangeAccent,
              side: const BorderSide(color: Colors.orangeAccent),
            ),
            onPressed: () {
              final reason = noteController.text.trim().isEmpty
                  ? 'Proof rejected • Returned to try again'
                  : noteController.text.trim();
              sync.rejectPlayerProof(active.id, reason: reason, returnToQueue: true);
              engine.returnProofToQueue(active.id, reason: reason);
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Returned "${active.order.title}" to active queue.'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.gavel_rounded, size: 16),
            label: Text('Reject & Penalize (-${active.order.penaltyTokens})'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              final reason = noteController.text.trim().isEmpty
                  ? 'Proof rejected by Director'
                  : noteController.text.trim();
              sync.rejectPlayerProof(active.id, reason: reason, returnToQueue: false);
              engine.rejectProof(active.id, reason: reason, penalize: true);
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Rejected and penalized "${active.order.title}".'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  void _showConfirmClearAllDirectivesDialog(BuildContext context, SyncService sync) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.cleaning_services_rounded, color: Colors.orangeAccent),
            SizedBox(width: 10),
            Text('Clear All Active Directives?'),
          ],
        ),
        content: const Text(
          'This will purge all active directives from your in-progress list on this device. Any stuck or legacy orders will be cleared immediately.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orangeAccent,
              foregroundColor: Colors.black,
            ),
            onPressed: () {
              sync.clearAllRemoteOrders();
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('All active directives cleared from queue.'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            child: const Text('Clear All Directives'),
          ),
        ],
      ),
    );
  }

  void _showConfirmClearAllReviewsDialog(BuildContext context, SyncService sync) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.cleaning_services_rounded, color: Colors.orangeAccent),
            SizedBox(width: 10),
            Text('Clear All Pending Reviews?'),
          ],
        ),
        content: const Text(
          'This will remove all pending proof reviews from your list on this device. Use this if old or stuck submissions are lingering.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orangeAccent,
              foregroundColor: Colors.black,
            ),
            onPressed: () {
              sync.clearAllRemoteReviews();
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('All pending reviews cleared.'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            child: const Text('Clear All Reviews'),
          ),
        ],
      ),
    );
  }

  void _showPurgeQueueDialog(BuildContext context, SyncService sync) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
            SizedBox(width: 10),
            Text('Purge Entire Queue?'),
          ],
        ),
        content: const Text(
          'This will wipe ALL active directives and pending reviews on this device. Use this if any legacy or ghost orders are stuck.\n\nTokens, streaks, rewards, and packs will NOT be affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              sync.purgeAllDirectivesAndReviews();
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Entire directive and review queue purged.'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            child: const Text('Purge Queue Now'),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoBadge({required IconData icon, required String label, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sync = Provider.of<SyncService>(context);
    final engine = Provider.of<OrderEngine>(context);
    final partnerSvc = Provider.of<PartnerService>(context);
    final theme = Theme.of(context);
    final hasRemoteData = sync.remoteReviewOrders.isNotEmpty ||
        sync.remoteActiveOrders.isNotEmpty ||
        sync.remotePendingRedemptions.isNotEmpty ||
        sync.remoteTokens > 0;
    final isRemote = (sync.status == ConnectionStatus.connected && sync.role == ConnectionRole.director) ||
        hasRemoteData ||
        partnerSvc.unblockedContacts.isNotEmpty;

    final myCode = sync.pairingCode;
    final myId = sync.deviceId;
    final activePartner = partnerSvc.activePartner;
    final partners = partnerSvc.unblockedContacts;

    final allReviews = [
      ...sync.remoteReviewOrders,
      ...engine.underReviewOrders.where((eo) => !sync.remoteReviewOrders.any((ro) => ro.id == eo.id || ro.order.title.toLowerCase() == eo.order.title.toLowerCase())),
    ];
    final reviewOrders = allReviews.where((o) {
      if (activePartner?.isSelf == true) {
        return o.assignedByPartnerId == PartnerContact.selfId;
      }
      if (o.assignedByPartnerId == PartnerContact.selfId) {
        return false;
      }
      // Strict Director Isolation: ONLY show directives dispatched by THIS Director
      if (!o.assignedByDirector) return false;

      final assignedCode = o.assignedByPartnerCode?.trim().toUpperCase();
      final assignedId = o.assignedByPartnerId?.trim();

      if (assignedCode != null && assignedCode.isNotEmpty) {
        if (myCode.isNotEmpty && assignedCode == myCode.toUpperCase()) return true;
        if (activePartner != null && activePartner.pairingCode.isNotEmpty && assignedCode == activePartner.pairingCode.toUpperCase()) return true;
      }
      if (assignedId != null && assignedId.isNotEmpty) {
        if (myId.isNotEmpty && assignedId == myId) return true;
        if (activePartner != null && activePartner.id.isNotEmpty && assignedId == activePartner.id) return true;
      }
      return false;
    }).toList();

    final pendingRedemptions = sync.remotePendingRedemptions.isNotEmpty ? sync.remotePendingRedemptions : engine.pendingRedemptions;

    final allActive = [
      ...sync.remoteActiveOrders,
      ...engine.currentRunningOrders.where((eo) => !sync.remoteActiveOrders.any((ro) => ro.id == eo.id || ro.order.title.toLowerCase() == eo.order.title.toLowerCase())),
    ].where((o) {
      if (o.status == OrderStatus.underReview) return false;
      return !allReviews.any((r) =>
          r.id == o.id ||
          (r.order.id.isNotEmpty && r.order.id == o.order.id) ||
          r.order.title.trim().toLowerCase() == o.order.title.trim().toLowerCase());
    }).toList();
    final activeOrders = allActive.where((o) {
      if (activePartner?.isSelf == true) {
        return o.assignedByPartnerId == PartnerContact.selfId;
      }
      if (o.assignedByPartnerId == PartnerContact.selfId) {
        return false;
      }
      // Strict Director Isolation: ONLY show directives dispatched by THIS Director
      if (!o.assignedByDirector) return false;

      final assignedCode = o.assignedByPartnerCode?.trim().toUpperCase();
      final assignedId = o.assignedByPartnerId?.trim();

      if (assignedCode != null && assignedCode.isNotEmpty) {
        if (myCode.isNotEmpty && assignedCode == myCode.toUpperCase()) return true;
        if (activePartner != null && activePartner.pairingCode.isNotEmpty && assignedCode == activePartner.pairingCode.toUpperCase()) return true;
      }
      if (assignedId != null && assignedId.isNotEmpty) {
        if (myId.isNotEmpty && assignedId == myId) return true;
        if (activePartner != null && activePartner.id.isNotEmpty && assignedId == activePartner.id) return true;
      }
      return false;
    }).toList();

    final playerTokens = sync.remoteTokens > 0 ? sync.remoteTokens : engine.stats.tokens;
    final playerStreak = sync.remoteStreak > 0 ? sync.remoteStreak : engine.stats.currentStreakDays;

    QuestService? questSvc;
    try {
      questSvc = Provider.of<QuestService>(context);
    } catch (_) {
      questSvc = sync.questService;
    }
    ActiveQuest? submissiveQuest;
    if (questSvc != null) {
      if (activePartner != null) {
        submissiveQuest = questSvc.remotePlayerQuests[activePartner.id] ??
            questSvc.remotePlayerQuests[activePartner.pairingCode];
      }
      submissiveQuest ??= questSvc.remotePlayerQuests.values.cast<ActiveQuest?>().firstWhere(
        (q) => q != null && !q.isCompleted,
        orElse: () => null,
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Connection status card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: sync.status == ConnectionStatus.connected
                          ? Colors.greenAccent.withOpacity(0.2)
                          : Colors.amber.withOpacity(0.2),
                      child: Icon(
                        sync.status == ConnectionStatus.connected
                            ? Icons.link_rounded
                            : Icons.link_off_rounded,
                        color: sync.status == ConnectionStatus.connected
                            ? Colors.greenAccent[400]
                            : Colors.amber,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'REMOTE LINK STATUS',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            activePartner?.isSelf == true
                                ? 'Self-Directive Control (This Device)'
                                : (sync.status == ConnectionStatus.connected
                                    ? 'Paired with ${activePartner?.displayName ?? "Submissive"}'
                                    : (activePartner != null ? 'Standby / Offline (${activePartner.displayName})' : 'Standby / Local Control')),
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (activePartner?.isSelf == true) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Your Balance: ${engine.stats.tokens} Tokens • ${engine.stats.currentStreakDays} Day Streak',
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ] else if (isRemote) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Submissive Balance: $playerTokens Tokens • $playerStreak Day Streak',
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (isRemote && (activePartner == null || !activePartner.isSelf)) ...[
                      IconButton(
                        tooltip: 'Refresh State from Player',
                        icon: const Icon(Icons.refresh_rounded, size: 20),
                        onPressed: () {
                          sync.requestStateFromPlayer();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Requested state update from submissive device...'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                      ),
                      IconButton(
                        tooltip: 'Disconnect',
                        icon: const Icon(Icons.link_off_rounded, size: 20),
                        onPressed: () => sync.disconnect(),
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Queue Management',
                        icon: const Icon(Icons.cleaning_services_rounded, size: 20, color: Colors.orangeAccent),
                        onSelected: (action) {
                          if (action == 'clear_active') {
                            _showConfirmClearAllDirectivesDialog(context, sync);
                          } else if (action == 'clear_reviews') {
                            _showConfirmClearAllReviewsDialog(context, sync);
                          } else if (action == 'purge_all') {
                            _showPurgeQueueDialog(context, sync);
                          }
                        },
                        itemBuilder: (ctx) => [
                          const PopupMenuItem(
                            enabled: false,
                            child: Text(
                              'SUBMISSIVE QUEUE RESET',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.1,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'clear_active',
                            child: Row(
                              children: [
                                Icon(Icons.delete_sweep_rounded, size: 18, color: Colors.orangeAccent),
                                SizedBox(width: 10),
                                Text('Clear All Active Directives'),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'clear_reviews',
                            child: Row(
                              children: [
                                Icon(Icons.rate_review_outlined, size: 18, color: Colors.amberAccent),
                                SizedBox(width: 10),
                                Text('Clear All Pending Reviews'),
                              ],
                            ),
                          ),
                          const PopupMenuDivider(),
                          const PopupMenuItem(
                            value: 'purge_all',
                            child: Row(
                              children: [
                                Icon(Icons.restart_alt_rounded, size: 18, color: Colors.redAccent),
                                SizedBox(width: 10),
                                Text('Purge Entire Directive Queue', style: TextStyle(color: Colors.redAccent)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
                const Divider(height: 20),
                Row(
                  children: [
                    const Icon(Icons.people_alt_outlined, size: 16, color: Colors.purpleAccent),
                    const SizedBox(width: 6),
                    Text(
                      'Active Submissive:',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onSurface.withOpacity(0.7),
                      ),
                    ),
                    const SizedBox(width: 10),
                    DropdownButton<String>(
                      value: partnerSvc.activePartnerId ?? PartnerContact.selfId,
                      isDense: true,
                      underline: const SizedBox(),
                      items: [
                        const DropdownMenuItem(
                          value: PartnerContact.selfId,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.person_rounded, size: 14, color: Colors.purpleAccent),
                              SizedBox(width: 6),
                              Text(
                                'Myself (This Device)',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                        ...partners.map((p) => DropdownMenuItem(
                          value: p.id,
                          child: Text(
                            p.displayName,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                          ),
                        )),
                      ],
                      onChanged: (newId) {
                        if (newId != null) {
                          if (newId == PartnerContact.selfId) {
                            partnerSvc.setActivePartner(PartnerContact.selfId);
                            sync.switchActivePartner(PartnerContact.self());
                          } else {
                            final target = partners.firstWhere((p) => p.id == newId);
                            partnerSvc.setActivePartner(target.id);
                            sync.switchActivePartner(target);
                          }
                        }
                      },
                    ),
                    const Spacer(),
                    if (activePartner != null && !activePartner.isSelf)
                      TextButton.icon(
                        icon: const Icon(Icons.chat_bubble_outline_rounded, size: 14),
                        label: const Text('Chat', style: TextStyle(fontSize: 12)),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ChatConversationView(partner: activePartner),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Action buttons row
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _showDispatchDialog(context),
                icon: const Icon(Icons.send_rounded, size: 18),
                label: const Text('Dispatch Order'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => ScheduleOrderDialog.show(context, isDirectorMode: true),
                icon: const Icon(Icons.schedule_rounded, size: 18),
                label: const Text('Schedule Order'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: BorderSide(color: theme.colorScheme.primary.withOpacity(0.5)),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _showTokenAdjustmentDialog(context),
                icon: const Icon(Icons.tune_rounded, size: 18),
                label: const Text('Adjust Tokens'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const RewardManagerView()),
                  );
                },
                icon: const Icon(Icons.storefront_rounded, size: 18),
                label: const Text('Privilege Shop'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),

        // Pending Privilege Redemptions Section
        if (pendingRedemptions.isNotEmpty) ...[
          Text(
            'PENDING PRIVILEGE REQUESTS (${pendingRedemptions.length})',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: Colors.amberAccent[700],
            ),
          ),
          const SizedBox(height: 8),
          ...pendingRedemptions.map(
            (redemption) => Card(
              margin: const EdgeInsets.symmetric(vertical: 6),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            redemption.reward.title,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Chip(
                          label: Text('${redemption.reward.cost} Tokens'),
                          backgroundColor: Colors.amber.withOpacity(0.15),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(redemption.reward.description, style: const TextStyle(fontSize: 13)),
                    if (redemption.note?.isNotEmpty == true) ...[
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('Player Note: "${redemption.note}"', style: const TextStyle(fontStyle: FontStyle.italic)),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      alignment: WrapAlignment.end,
                      children: [
                        TextButton.icon(
                          onPressed: () => engine.rejectRedemption(redemption.id),
                          icon: const Icon(Icons.close_rounded, size: 16),
                          label: const Text('Decline & Refund'),
                          style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                        ),
                        ElevatedButton.icon(
                          onPressed: () => engine.approveRedemption(redemption.id),
                          icon: const Icon(Icons.check_rounded, size: 16),
                          label: const Text('Grant Privilege'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],

        // Active Submissive Quest Protocol Section
        if (submissiveQuest != null && !submissiveQuest.isCompleted) ...[
          _buildSubmissiveQuestCard(context, submissiveQuest, activePartner, sync, theme),
          const SizedBox(height: 24),
        ],

        // Active Dispatched Orders in Progress section
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'ACTIVE DIRECTIVES IN PROGRESS (${activeOrders.length})',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
                color: theme.colorScheme.primary,
              ),
            ),
            if (activeOrders.isNotEmpty)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.sync_rounded, size: 14),
                    label: const Text('Re-sync All', style: TextStyle(fontSize: 11)),
                    onPressed: () {
                      sync.forceResyncDashboard();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Re-syncing and requesting state from submissive...'),
                          behavior: SnackBarBehavior.floating,
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (activeOrders.any((o) => o.status == OrderStatus.failed)) ...[
                    TextButton.icon(
                      icon: const Icon(Icons.cleaning_services_rounded, size: 14),
                      label: const Text('Clear Failed', style: TextStyle(fontSize: 11)),
                      onPressed: () => sync.clearAllFailedRemoteOrders(),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: Colors.redAccent,
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  TextButton.icon(
                    icon: const Icon(Icons.delete_sweep_rounded, size: 14),
                    label: const Text('Clear All', style: TextStyle(fontSize: 11)),
                    onPressed: () => _showConfirmClearAllDirectivesDialog(context, sync),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: theme.colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                ],
              ),
          ],
        ),
        const SizedBox(height: 8),

        if (activeOrders.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  'No active directives currently dispatched to submissive.',
                  style: TextStyle(
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
              ),
            ),
          )
        else
          ...activeOrders.map(
            (active) {
              final isConfirmedOnDevice = sync.isOrderConfirmedOnPlayer(active);

              return Card(
                margin: const EdgeInsets.symmetric(vertical: 6),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              active.order.category.toUpperCase(),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Chip(
                            visualDensity: VisualDensity.compact,
                            label: Text('Tier ${active.order.tier}', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold)),
                          ),
                          if (active.assignedByPartnerName != null && active.assignedByPartnerName!.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.purpleAccent.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.person_rounded, size: 11, color: Colors.purpleAccent),
                                  const SizedBox(width: 4),
                                  Text(
                                    active.assignedByPartnerName!,
                                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.purpleAccent),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const Spacer(),
                          Chip(
                            label: Text('+${active.order.rewardTokens} / -${active.order.penaltyTokens}'),
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        active.order.title,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        active.order.description,
                        style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withOpacity(0.8)),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          _buildInfoBadge(
                            icon: Icons.timer_outlined,
                            label: active.order.formattedTiming,
                            color: theme.colorScheme.primary,
                          ),
                          _buildInfoBadge(
                            icon: Icons.verified_outlined,
                            label: active.order.verificationType.displayName,
                            color: Colors.amberAccent[700]!,
                          ),
                          if (active.order.requiredEquipment.isNotEmpty)
                            _buildInfoBadge(
                              icon: Icons.lock_outline_rounded,
                              label: 'Requires: ${active.order.requiredEquipment.join(", ")}',
                              color: Colors.orangeAccent,
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        alignment: WrapAlignment.spaceBetween,
                        children: [
                          if (active.status == OrderStatus.failed) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.redAccent.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.cancel_rounded, size: 14, color: Colors.redAccent),
                                  const SizedBox(width: 6),
                                  Text(
                                    'FAILED: ${active.directorNote ?? "Forfeited / Expired"}',
                                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.redAccent),
                                  ),
                                ],
                              ),
                            ),
                          ] else if (isConfirmedOnDevice) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.greenAccent.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: Colors.greenAccent.withOpacity(0.35)),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.circle, size: 8, color: Colors.greenAccent),
                                  SizedBox(width: 6),
                                  Text(
                                    'Active on Submissive\'s Device',
                                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.greenAccent),
                                  ),
                                ],
                              ),
                            ),
                          ] else ...[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.amberAccent.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: Colors.amberAccent.withOpacity(0.35)),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.circle, size: 8, color: Colors.amberAccent),
                                  SizedBox(width: 6),
                                  Text(
                                    'Dispatch Pending • Syncing',
                                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.amberAccent),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            alignment: WrapAlignment.end,
                            children: [
                              OutlinedButton.icon(
                                icon: const Icon(Icons.send_rounded, size: 13),
                                label: const Text('Re-send', style: TextStyle(fontSize: 11)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: isConfirmedOnDevice ? theme.colorScheme.primary : Colors.amberAccent,
                                  side: BorderSide(
                                    color: isConfirmedOnDevice
                                        ? theme.colorScheme.primary.withOpacity(0.4)
                                        : Colors.amberAccent.withOpacity(0.6),
                                  ),
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: () {
                                  sync.resendDispatchedOrder(active);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('Re-sent "${active.order.title}" to Submissive.'),
                                      behavior: SnackBarBehavior.floating,
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                },
                              ),
                              TextButton.icon(
                                icon: const Icon(Icons.clear_rounded, size: 14),
                                label: const Text('Clear', style: TextStyle(fontSize: 11)),
                                style: TextButton.styleFrom(
                                  foregroundColor: theme.colorScheme.onSurface.withOpacity(0.6),
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: () {
                                  sync.clearRemoteActiveOrder(
                                    active.id,
                                    orderId: active.order.id,
                                    orderTitle: active.order.title,
                                  );
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('Cleared "${active.order.title}" from queue.'),
                                      behavior: SnackBarBehavior.floating,
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                },
                              ),
                              if (active.status != OrderStatus.failed)
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.undo_rounded, size: 14),
                                  label: const Text('Recall'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.redAccent,
                                    side: BorderSide(color: Colors.redAccent.withOpacity(0.4)),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  onPressed: () {
                                    sync.recallDispatchedOrder(
                                      active.id,
                                      orderId: active.order.id,
                                      orderTitle: active.order.title,
                                      partnerCode: active.assignedByPartnerCode,
                                    );
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('Recalled "${active.order.title}" and cleared from queue.'),
                                        behavior: SnackBarBehavior.floating,
                                        duration: const Duration(seconds: 2),
                                      ),
                                    );
                                  },
                                ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        const SizedBox(height: 24),

        // Submissions for Review section
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'PENDING PROOF REVIEWS (${reviewOrders.length})',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
            if (reviewOrders.isNotEmpty)
              TextButton.icon(
                icon: const Icon(Icons.delete_sweep_rounded, size: 14),
                label: const Text('Clear All Reviews', style: TextStyle(fontSize: 11)),
                onPressed: () => _showConfirmClearAllReviewsDialog(context, sync),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: theme.colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),

        if (reviewOrders.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  'No pending submissions to review.',
                  style: TextStyle(
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
              ),
            ),
          )
        else
          ...reviewOrders.map(
            (active) => Card(
              margin: const EdgeInsets.symmetric(vertical: 6),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            active.order.title,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Chip(
                          label: Text('+${active.order.rewardTokens} / -${active.order.penaltyTokens}'),
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                    if (active.order.durationType == DurationType.actionTimer ||
                        active.order.durationType == DurationType.actionWithDeadline) ...[
                      const SizedBox(height: 6),
                      if (!active.isActionTimerFinished && active.actionSecondsRemaining > 0)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.redAccent.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.warning_amber_rounded, size: 18, color: Colors.redAccent),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'EARLY SUBMISSION • INCOMPLETE TIMER',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.redAccent,
                                        letterSpacing: 0.8,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Submitted early with ${OrderItem.formatSecondsHuman(active.actionSecondsRemaining)} left uncompleted (out of ${OrderItem.formatSecondsHuman(active.order.actionDurationSeconds)}).',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.greenAccent.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.greenAccent.withOpacity(0.3)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.check_circle_outline_rounded, size: 16, color: Colors.greenAccent),
                              const SizedBox(width: 8),
                              Text(
                                'Action timer completed (${OrderItem.formatSecondsHuman(active.order.actionDurationSeconds)})',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.greenAccent,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                    if (active.submissionProof?.isNotEmpty == true) ...[
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          active.submissionProof!,
                          style: const TextStyle(fontStyle: FontStyle.italic),
                        ),
                      ),
                    ],
                    if (active.proofImageBase64 != null) ...[
                      const SizedBox(height: 10),
                      GestureDetector(
                        onTap: () => _showExpandedImageDialog(
                          context,
                          active.proofImageBase64!,
                          active.order.title,
                        ),
                        child: Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.memory(
                                base64Decode(active.proofImageBase64!),
                                height: 180,
                                width: double.infinity,
                                fit: BoxFit.cover,
                              ),
                            ),
                            Positioned(
                              bottom: 8,
                              right: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.75),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.zoom_in_rounded, size: 14, color: Colors.white),
                                    SizedBox(width: 4),
                                    Text('Tap to Inspect', style: TextStyle(fontSize: 11, color: Colors.white)),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      alignment: WrapAlignment.spaceBetween,
                      children: [
                        TextButton.icon(
                          onPressed: () {
                            sync.clearRemoteReviewOrder(
                              active.id,
                              orderId: active.order.id,
                              orderTitle: active.order.title,
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Dismissed review for "${active.order.title}".'),
                                behavior: SnackBarBehavior.floating,
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          },
                          icon: const Icon(Icons.clear_rounded, size: 16),
                          label: const Text('Dismiss'),
                          style: TextButton.styleFrom(
                            foregroundColor: theme.colorScheme.onSurface.withOpacity(0.6),
                          ),
                        ),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          alignment: WrapAlignment.end,
                          children: [
                            TextButton.icon(
                              onPressed: () => _showRejectProofDialog(context, active, sync, engine),
                              icon: const Icon(Icons.close_rounded, size: 16),
                              label: const Text('Reject Proof'),
                              style: TextButton.styleFrom(
                                foregroundColor: theme.colorScheme.error,
                              ),
                            ),
                            ElevatedButton.icon(
                              onPressed: () {
                                sync.approvePlayerProof(active.id);
                                engine.approveProof(active.id);
                              },
                              icon: const Icon(Icons.check_rounded, size: 16),
                              label: const Text('Approve & Reward'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSubmissiveQuestCard(
    BuildContext context,
    ActiveQuest quest,
    PartnerContact? partner,
    SyncService sync,
    ThemeData theme,
  ) {
    final currentStep = quest.currentStep;
    final stepNum = quest.currentStepIndex + 1;
    final totalSteps = quest.totalSteps;
    final progress = quest.progressFraction;

    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.purpleAccent.withOpacity(0.4), width: 1.5),
      ),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [
              Colors.purple.withOpacity(0.12),
              theme.colorScheme.surface,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.purpleAccent.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.auto_stories_rounded, size: 14, color: Colors.purpleAccent),
                      SizedBox(width: 5),
                      Text(
                        'ACTIVE SUBMISSIVE QUEST',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1,
                          color: Colors.purpleAccent,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.cyanAccent.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Step $stepNum of $totalSteps',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.cyanAccent,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              quest.quest.title,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (quest.quest.description.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                quest.quest.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurface.withOpacity(0.7),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'Current Directive: ${currentStep?.title ?? "In Progress"}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.cyanAccent,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '+${quest.quest.bonusTokensOnComplete} Tokens Bounty',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.amber,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 7,
                backgroundColor: theme.colorScheme.onSurface.withOpacity(0.1),
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.purpleAccent),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.send_rounded, size: 14),
                  label: const Text('Re-dispatch / Push to Submissive', style: TextStyle(fontSize: 11)),
                  onPressed: () {
                    sync.dispatchQuestToPlayer(quest.quest, targetPartner: partner);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Re-dispatched quest "${quest.quest.title}" to submissive!'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
