import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/order_engine.dart';
import '../../services/sync_service.dart';
import '../../services/partner_service.dart';
import '../../models/active_order.dart';
import '../../models/order_item.dart';
import '../../models/partner_contact.dart';
import '../../models/sync_message.dart';
import '../../widgets/order_card.dart';
import '../../widgets/token_badge.dart';
import '../../widgets/draggable_dialog.dart';
import '../../core/utils/image_compressor.dart';
import '../scheduling/schedule_order_dialog.dart';

class PlayerDashboardView extends StatelessWidget {
  const PlayerDashboardView({super.key});

  void _showDrawOrderDialog(BuildContext context) {
    final engine = Provider.of<OrderEngine>(context, listen: false);
    String? selectedCategory;
    int minTier = 1;
    int maxTier = 5;

    final categories = engine.packs
        .where((p) => p.isEnabled)
        .expand((p) => p.orders)
        .map((o) => o.category)
        .toSet()
        .toList();

    DraggableDialog.show(
      context: context,
      title: 'Request / Draw Order',
      maxWidth: 520,
      builder: (ctx, setModalState) {
        final theme = Theme.of(ctx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Category Filter (Optional)',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  showCheckmark: false,
                  label: const Text('All Categories'),
                  selected: selectedCategory == null,
                  onSelected: (val) {
                    if (val) setModalState(() => selectedCategory = null);
                  },
                ),
                ...categories.map(
                  (cat) => ChoiceChip(
                    showCheckmark: false,
                    label: Text(cat),
                    selected: selectedCategory == cat,
                    onSelected: (val) {
                      setModalState(() => selectedCategory = val ? cat : null);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Difficulty Tier Range',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: theme.colorScheme.primary.withOpacity(0.3)),
                  ),
                  child: Text(
                    minTier == maxTier ? 'Tier $minTier' : 'Tier $minTier – Tier $maxTier',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            RangeSlider(
              values: RangeValues(minTier.toDouble(), maxTier.toDouble()),
              min: 1,
              max: 5,
              divisions: 4,
              labels: RangeLabels('Tier $minTier', 'Tier $maxTier'),
              onChanged: (RangeValues values) {
                setModalState(() {
                  minTier = values.start.round();
                  maxTier = values.end.round();
                });
              },
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Min: Tier $minTier', style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.6))),
                Text('Max: Tier $maxTier', style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.6))),
              ],
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.bolt_rounded),
                label: const Text('Draw Random Order'),
                onPressed: () {
                  final drawn = engine.drawRandomOrder(
                    category: selectedCategory,
                    minTier: minTier,
                    maxTier: maxTier,
                  );
                  Navigator.pop(ctx);

                  if (drawn != null) {
                    engine.assignOrder(drawn);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Assigned: ${drawn.title} (Tier ${drawn.tier})'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  } else {
                    final reason = engine.getDrawRandomOrderFailureReason(
                          category: selectedCategory,
                          minTier: minTier,
                          maxTier: maxTier,
                        ) ??
                        'No directives available matching criteria.';
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(reason),
                        duration: const Duration(seconds: 4),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  }
                },
              ),
            ),
          ],
        );
      },
    );
  }

  void _showProofSubmissionDialog(BuildContext context, ActiveOrder activeOrder) {
    final engine = Provider.of<OrderEngine>(context, listen: false);
    final partnerService = Provider.of<PartnerService>(context, listen: false);
    final syncService = Provider.of<SyncService>(context, listen: false);
    final unblockedPartners = partnerService.unblockedContacts;

    final textController = TextEditingController(text: activeOrder.submissionProof ?? '');
    String? attachedImageBase64 = activeOrder.proofImageBase64;
    String? attachedImageName = activeOrder.proofImageBase64 != null ? 'Attached Photo' : null;

    final bool isDirectorAssigned = activeOrder.assignedByDirector &&
        ((activeOrder.assignedByPartnerId != null && activeOrder.assignedByPartnerId!.isNotEmpty) ||
            (activeOrder.assignedByPartnerCode != null && activeOrder.assignedByPartnerCode!.isNotEmpty));

    String selectedMode = isDirectorAssigned ? 'director' : 'skip';
    String? selectedDirectorId = isDirectorAssigned
        ? (activeOrder.assignedByPartnerId ?? (unblockedPartners.isNotEmpty ? unblockedPartners.first.id : null))
        : (unblockedPartners.isNotEmpty ? unblockedPartners.first.id : null);

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final theme = Theme.of(context);
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  const Icon(Icons.rate_review_rounded, color: Colors.cyanAccent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      activeOrder.status == OrderStatus.underReview ? 'Resubmit Proof' : 'Proof Submission',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 480,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.assignment_turned_in_rounded, size: 20, color: Colors.cyanAccent),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                activeOrder.order.title,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Verification Destination Option
                      if (isDirectorAssigned) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.cyanAccent.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.verified_user_rounded, size: 16, color: Colors.cyanAccent),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Assigned by Director: ${activeOrder.assignedByPartnerName ?? "Connected Partner"}',
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.cyanAccent),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ] else ...[
                        Text(
                          'Verification Method',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface.withOpacity(0.8),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Card(
                          margin: EdgeInsets.zero,
                          child: Column(
                            children: [
                              RadioListTile<String>(
                                title: const Text('Self-Verify / Skip Director Verification', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                subtitle: const Text('Complete task instantly and award tokens immediately.', style: TextStyle(fontSize: 11)),
                                value: 'skip',
                                groupValue: selectedMode,
                                onChanged: (val) => setDialogState(() => selectedMode = val ?? 'skip'),
                              ),
                              if (unblockedPartners.isNotEmpty) ...[
                                const Divider(height: 1),
                                RadioListTile<String>(
                                  title: const Text('Send to Connected Director for Review', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                  subtitle: const Text('Submit note & photo proof to an attached Director to verify.', style: TextStyle(fontSize: 11)),
                                  value: 'director',
                                  groupValue: selectedMode,
                                  onChanged: (val) => setDialogState(() => selectedMode = val ?? 'director'),
                                ),
                                if (selectedMode == 'director') ...[
                                  Padding(
                                    padding: const EdgeInsets.only(left: 16, right: 16, bottom: 12),
                                    child: DropdownButtonFormField<String>(
                                      value: selectedDirectorId,
                                      decoration: const InputDecoration(
                                        labelText: 'Select Attached Director',
                                        prefixIcon: Icon(Icons.person_pin_rounded, size: 18),
                                      ),
                                      items: unblockedPartners.map((p) {
                                        final roleLabel = p.role == PartnerRole.dominant ? 'Director' : p.role.name;
                                        return DropdownMenuItem(
                                          value: p.id,
                                          child: Text('${p.displayName} ($roleLabel)'),
                                        );
                                      }).toList(),
                                      onChanged: (val) => setDialogState(() => selectedDirectorId = val),
                                    ),
                                  ),
                                ],
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],

                      Text(
                        'Completion Note / Details',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface.withOpacity(0.8),
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: textController,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          hintText: 'e.g. Performed with zero infractions, ready for inspection...',
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Photo / Image Proof (Optional)',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface.withOpacity(0.8),
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (attachedImageBase64 != null) ...[
                        Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.memory(
                                base64Decode(attachedImageBase64!),
                                height: 180,
                                width: double.infinity,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) => Container(
                                  height: 100,
                                  color: Colors.redAccent.withOpacity(0.2),
                                  child: const Center(child: Text('Invalid image data')),
                                ),
                              ),
                            ),
                            Positioned(
                              top: 6,
                              right: 6,
                              child: CircleAvatar(
                                radius: 14,
                                backgroundColor: Colors.black.withOpacity(0.75),
                                child: IconButton(
                                  padding: EdgeInsets.zero,
                                  icon: const Icon(Icons.close_rounded, size: 16, color: Colors.white),
                                  onPressed: () {
                                    setDialogState(() {
                                      attachedImageBase64 = null;
                                      attachedImageName = null;
                                    });
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],
                      OutlinedButton.icon(
                        onPressed: () async {
                          try {
                            final picker = ImagePicker();
                            final image = await picker.pickImage(
                              source: ImageSource.gallery,
                              maxWidth: 1600,
                              maxHeight: 1600,
                              imageQuality: 85,
                            );
                            if (image != null) {
                              final bytes = await image.readAsBytes();
                              final compressedBase64 = ImageCompressor.compressAndEncode(bytes) ?? base64Encode(bytes);
                              setDialogState(() {
                                attachedImageBase64 = compressedBase64;
                                attachedImageName = image.name;
                              });
                            }
                          } catch (e) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Could not attach image: $e')),
                            );
                          }
                        },
                        icon: const Icon(Icons.add_a_photo_rounded, size: 16),
                        label: Text(attachedImageBase64 != null
                            ? 'Change Photo (${attachedImageName ?? 'Attached'})'
                            : 'Attach Photo Proof'),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                ElevatedButton.icon(
                  icon: Icon(selectedMode == 'skip' ? Icons.check_circle_rounded : Icons.send_rounded, size: 16),
                  label: Text(
                    selectedMode == 'skip'
                        ? 'Self-Verify & Complete'
                        : (activeOrder.status == OrderStatus.underReview ? 'Resubmit Proof' : 'Submit to Director'),
                  ),
                  onPressed: () async {
                    final confirmed = await _confirmIncompleteActionTimerSubmission(context, activeOrder);
                    if (!confirmed) return;

                    final note = textController.text.trim();

                    if (selectedMode == 'skip') {
                      engine.completeOrder(activeOrder.id, proofNote: note);
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Task self-verified & completed! Awarded ${activeOrder.order.rewardTokens} tokens.'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    } else {
                      PartnerContact? partner;
                      if (selectedDirectorId != null) {
                        partner = unblockedPartners.firstWhere(
                          (p) => p.id == selectedDirectorId,
                          orElse: () => unblockedPartners.first,
                        );
                      }

                      if (!activeOrder.assignedByDirector && partner != null) {
                        final idx = engine.activeOrders.indexWhere((o) => o.id == activeOrder.id);
                        if (idx != -1) {
                          engine.activeOrders[idx] = activeOrder.copyWith(
                            assignedByDirector: true,
                            assignedByPartnerId: partner.id,
                            assignedByPartnerCode: partner.pairingCode,
                            assignedByPartnerName: partner.displayName,
                          );
                        }
                      }

                      engine.submitOrCompleteOrder(
                        activeOrder.id,
                        proofNote: note,
                        proofImageBase64: attachedImageBase64,
                      );

                      final updated = engine.underReviewOrders.firstWhere(
                        (o) => o.id == activeOrder.id,
                        orElse: () => activeOrder.copyWith(
                          status: OrderStatus.underReview,
                          submissionProof: note,
                          proofImageBase64: attachedImageBase64,
                          assignedByDirector: true,
                          assignedByPartnerId: partner?.id,
                          assignedByPartnerCode: partner?.pairingCode,
                          assignedByPartnerName: partner?.displayName,
                        ),
                      );

                      syncService.sendProofForReview(updated);
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Submission sent to ${updated.assignedByPartnerName ?? "Director"} for verification'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<bool> _confirmIncompleteActionTimerSubmission(
    BuildContext context,
    ActiveOrder activeOrder,
  ) async {
    final hasActionTimer = activeOrder.order.durationType == DurationType.actionTimer ||
        activeOrder.order.durationType == DurationType.actionWithDeadline;

    if (!hasActionTimer || activeOrder.isActionTimerFinished || activeOrder.actionSecondsRemaining <= 0) {
      return true;
    }

    final remainingStr = OrderItem.formatSecondsHuman(activeOrder.actionSecondsRemaining);
    final totalStr = OrderItem.formatSecondsHuman(activeOrder.order.actionDurationSeconds);

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Incomplete Action Timer',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "This task hasn't been completed, are you sure?",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 8),
              Text(
                'There is still $remainingStr left on the action timer (out of $totalStr). If you submit now, this will be flagged as an early submission on the proof review.',
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orangeAccent[700],
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Submit'),
            ),
          ],
        );
      },
    );

    return result ?? false;
  }

  void _showForfeitConfirmation(BuildContext context, ActiveOrder activeOrder) {
    final engine = Provider.of<OrderEngine>(context, listen: false);

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Forfeit Order?'),
          content: Text(
            'Forfeiting this task will deduct ${activeOrder.order.penaltyTokens} tokens and be logged on your record.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Keep Trying'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                engine.failOrder(activeOrder.id, reason: 'Voluntarily forfeited');
                final sync = Provider.of<SyncService>(context, listen: false);
                if (activeOrder.assignedByDirector) {
                  sync.sendMessage(
                    SyncMessage(
                      type: SyncMessageType.orderStatusUpdate,
                      senderId: sync.deviceId,
                      payload: {
                        'activeOrderId': activeOrder.id,
                        'status': 'failed',
                        'orderTitle': activeOrder.order.title,
                        'reason': 'Voluntarily forfeited',
                        'senderName': sync.nickname.isNotEmpty ? sync.nickname : 'Player',
                        'senderCode': sync.pairingCode,
                      },
                    ),
                  );
                }
                sync.broadcastPlayerState();
                Navigator.pop(ctx);
              },
              child: const Text('Confirm Forfeit'),
            ),
          ],
        );
      },
    );
  }

  void _showCleanDashboardDialog(BuildContext context) {
    final engine = Provider.of<OrderEngine>(context, listen: false);
    final sync = Provider.of<SyncService>(context, listen: false);
    final theme = Theme.of(context);

    showModalBottomSheet(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.cleaning_services_rounded, color: Colors.cyanAccent),
                    const SizedBox(width: 10),
                    Text(
                      'Dashboard Management',
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Clean up expired, completed, or stuck tasks.',
                  style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withOpacity(0.6)),
                ),
                const SizedBox(height: 16),
                ListTile(
                  leading: const Icon(Icons.check_circle_outline_rounded, color: Colors.greenAccent),
                  title: const Text('Clear Finished & Failed Tasks'),
                  subtitle: const Text('Removes completed, expired, and forfeited tasks'),
                  onTap: () {
                    engine.clearAllFinishedAndFailedOrders();
                    sync.broadcastPlayerState();
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Cleared finished and failed tasks')),
                    );
                  },
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.delete_sweep_rounded, color: Colors.redAccent),
                  title: const Text('Emergency Clear All Directives', style: TextStyle(color: Colors.redAccent)),
                  subtitle: const Text('Wipes all active and under-review tasks (Clean Slate)'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showEmergencyClearConfirmDialog(context);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showEmergencyClearConfirmDialog(BuildContext context) {
    final engine = Provider.of<OrderEngine>(context, listen: false);
    final sync = Provider.of<SyncService>(context, listen: false);

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Clear All Directives?'),
          content: const Text(
            'This will clear all running and under-review tasks from your dashboard to give you a clean slate.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                engine.clearAllActiveOrders();
                sync.broadcastPlayerState();
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Dashboard cleared')),
                );
              },
              child: const Text('Confirm Clear All'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final engine = Provider.of<OrderEngine>(context);
    final theme = Theme.of(context);
    final runningOrders = engine.currentRunningOrders;
    final reviewOrders = engine.underReviewOrders;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        // Status & Stats Banner
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'STATUS HUD',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      runningOrders.isEmpty ? 'Ready for Assignment' : '${runningOrders.length} In Progress',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Clean / Override Tasks',
                  icon: const Icon(Icons.cleaning_services_rounded, size: 20),
                  onPressed: () => _showCleanDashboardDialog(context),
                ),
                const SizedBox(width: 4),
                TokenBadge(
                  tokens: engine.stats.tokens,
                  streakDays: engine.stats.currentStreakDays,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Action Trigger Buttons
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _showDrawOrderDialog(context),
                icon: const Icon(Icons.bolt_rounded, size: 20),
                label: const Text('PULL NEW ORDER'),
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
                onPressed: () => ScheduleOrderDialog.show(context, isDirectorMode: false),
                icon: const Icon(Icons.schedule_rounded, size: 20),
                label: const Text('SCHEDULE ORDER'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: BorderSide(color: theme.colorScheme.primary.withOpacity(0.5)),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // Active Orders List
        if (runningOrders.isNotEmpty) ...[
          Text(
            'ACTIVE DIRECTIVES',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: theme.colorScheme.onSurface.withOpacity(0.6),
            ),
          ),
          const SizedBox(height: 8),
          ...runningOrders.map(
            (active) => OrderCard(
              activeOrder: active,
              onComplete: () async {
                final confirmed = await _confirmIncompleteActionTimerSubmission(context, active);
                if (!confirmed) return;
                engine.completeOrder(active.id);
              },
              onSubmitProof: () => _showProofSubmissionDialog(context, active),
              onForfeit: () => _showForfeitConfirmation(context, active),
              onDismiss: () => engine.dismissOrDeleteOrder(active.id),
            ),
          ),
        ],

        // Under Review Section
        if (reviewOrders.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            'AWAITING VERIFICATION (${reviewOrders.length})',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: Colors.amberAccent[700],
            ),
          ),
          const SizedBox(height: 8),
          ...reviewOrders.map(
            (active) => Card(
              margin: const EdgeInsets.symmetric(vertical: 6),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.hourglass_top_rounded, color: Colors.amber, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            active.order.title,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                        ),
                        const Chip(
                          label: Text('Under Review', style: TextStyle(fontSize: 11)),
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
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.orangeAccent.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.orangeAccent.withOpacity(0.4)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orangeAccent),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Submitted early with ${OrderItem.formatSecondsHuman(active.actionSecondsRemaining)} remaining on timer',
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.orangeAccent),
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
                              const Icon(Icons.timer_rounded, size: 16, color: Colors.greenAccent),
                              const SizedBox(width: 8),
                              Text(
                                'Action timer completed (${OrderItem.formatSecondsHuman(active.order.actionDurationSeconds)})',
                                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.greenAccent),
                              ),
                            ],
                          ),
                        ),
                    ],
                    if (active.assignedByDirector) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.lock_person_rounded, size: 13, color: Colors.purpleAccent.withOpacity(0.9)),
                          const SizedBox(width: 4),
                          Text(
                            'Assigned by: ${active.assignedByPartnerName ?? 'Director'}${active.assignedByPartnerCode != null && active.assignedByPartnerCode!.isNotEmpty ? ' (${active.assignedByPartnerCode})' : ''}',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.purpleAccent.withOpacity(0.9),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (active.submissionProof?.isNotEmpty == true) ...[
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Note: "${active.submissionProof}"',
                          style: const TextStyle(fontStyle: FontStyle.italic, fontSize: 13),
                        ),
                      ),
                    ],
                    if (active.proofImageBase64 != null) ...[
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(
                          base64Decode(active.proofImageBase64!),
                          height: 120,
                          width: double.infinity,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton.icon(
                          onPressed: () => engine.dismissOrDeleteOrder(active.id),
                          icon: const Icon(Icons.delete_outline_rounded, size: 16),
                          label: const Text('Dismiss'),
                          style: TextButton.styleFrom(
                            foregroundColor: theme.colorScheme.onSurface.withOpacity(0.5),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: () => _showProofSubmissionDialog(context, active),
                          icon: const Icon(Icons.refresh_rounded, size: 16),
                          label: const Text('Resubmit Proof'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],

        if (runningOrders.isEmpty && reviewOrders.isEmpty) ...[
          const SizedBox(height: 40),
          Center(
            child: Column(
              children: [
                Icon(
                  Icons.task_alt_rounded,
                  size: 56,
                  color: theme.colorScheme.onSurface.withOpacity(0.3),
                ),
                const SizedBox(height: 12),
                Text(
                  'No Active Orders',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface.withOpacity(0.6),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Pull a new order or wait for your Director to assign one.',
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.onSurface.withOpacity(0.4),
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
