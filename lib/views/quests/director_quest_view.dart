import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../../models/quest_item.dart';
import '../../models/quest_pack.dart';
import '../../models/order_item.dart';
import '../../models/order_pack.dart';
import '../../models/partner_contact.dart';
import '../../services/quest_service.dart';
import '../../services/sync_service.dart';
import '../../services/partner_service.dart';
import '../../services/order_engine.dart';
import '../../core/security/encryption_helper.dart';
import '../../widgets/draggable_dialog.dart';

class DirectorQuestView extends StatefulWidget {
  const DirectorQuestView({super.key});

  @override
  State<DirectorQuestView> createState() => _DirectorQuestViewState();
}

class _DirectorQuestViewState extends State<DirectorQuestView> {
  void _openQuestEditor([Quest? existing]) {
    final titleCtrl = TextEditingController(text: existing?.title ?? '');
    final descCtrl = TextEditingController(text: existing?.description ?? '');
    final catCtrl = TextEditingController(text: existing?.category ?? 'General Gauntlet');
    final bonusCtrl = TextEditingController(text: '${existing?.bonusTokensOnComplete ?? 25}');

    final steps = existing != null ? List<QuestStep>.from(existing.steps) : <QuestStep>[];

    DraggableDialog.show(
      context: context,
      title: existing != null ? 'Edit Quest Playlist' : 'Create Quest Playlist',
      maxWidth: 600,
      builder: (dialogCtx, setDialogState) {
        final theme = Theme.of(dialogCtx);

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(
                labelText: 'Quest Title *',
                hintText: 'e.g. Evening Obedience Protocol',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Description / Purpose',
                hintText: 'Provide context for this chain of directives...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: catCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Category / Theme',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: bonusCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Completion Bonus Tokens',
                      prefixIcon: Icon(Icons.stars_rounded, color: Colors.amber),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Steps Header with Add Step and Add Existing Directives
            Row(
              children: [
                Expanded(
                  child: Text(
                    'CHAINED STEPS (${steps.length})',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.playlist_add_rounded, size: 18),
                  label: const Text('Add Existing'),
                  onPressed: () {
                    _openExistingDirectivePicker(
                      onAddDirectives: (selectedOrders) {
                        setDialogState(() {
                          for (final order in selectedOrders) {
                            steps.add(
                              QuestStep(
                                orderIndex: steps.length + 1,
                                title: order.title,
                                description: order.description,
                                durationType: order.durationType,
                                durationMinutes: order.durationMinutes,
                                actionDurationSeconds: order.actionDurationSeconds,
                                rewardTokens: order.rewardTokens,
                                verificationType: order.verificationType,
                                requiredEquipment: List.from(order.requiredEquipment),
                              ),
                            );
                          }
                        });
                      },
                    );
                  },
                ),
                const SizedBox(width: 4),
                TextButton.icon(
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('New Step'),
                  onPressed: () {
                    _openStepEditor(
                      onSave: (newStep) {
                        setDialogState(() {
                          steps.add(newStep.copyWith(orderIndex: steps.length + 1));
                        });
                      },
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 6),

            if (steps.isEmpty)
              Container(
                padding: const EdgeInsets.all(24),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: theme.colorScheme.outline.withOpacity(0.2)),
                ),
                child: Text(
                  'No steps in this quest yet.\nTap "Add Existing" to import directives or "New Step" to create custom ones.',
                  style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 13, height: 1.4),
                  textAlign: TextAlign.center,
                ),
              )
            else
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: steps.length,
                onReorder: (oldIndex, newIndex) {
                  setDialogState(() {
                    if (newIndex > oldIndex) newIndex -= 1;
                    final item = steps.removeAt(oldIndex);
                    steps.insert(newIndex, item);
                    for (int i = 0; i < steps.length; i++) {
                      steps[i] = steps[i].copyWith(orderIndex: i + 1);
                    }
                  });
                },
                itemBuilder: (context, index) {
                  final step = steps[index];
                  final isAction = step.durationType == DurationType.actionTimer;
                  final isDeadline = step.durationType == DurationType.deadlineCountdown;
                  final timingText = isAction
                      ? '${step.actionDurationSeconds > 0 ? OrderItem.formatSecondsHuman(step.actionDurationSeconds) : "${step.durationMinutes}m"} Action'
                      : isDeadline
                          ? '${step.durationMinutes}m Deadline'
                          : 'Untimed';

                  return Card(
                    key: ValueKey(step.id),
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: CircleAvatar(
                        radius: 14,
                        backgroundColor: theme.colorScheme.primary.withOpacity(0.2),
                        foregroundColor: theme.colorScheme.primary,
                        child: Text('${index + 1}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                      ),
                      title: Text(step.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                      subtitle: Text(
                        '+${step.rewardTokens} Tokens • $timingText${step.isHiddenUntilUnlocked ? " • Mystery 🔒" : ""}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            onPressed: () {
                              _openStepEditor(
                                existing: step,
                                onSave: (updated) {
                                  setDialogState(() {
                                    steps[index] = updated;
                                  });
                                },
                              );
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline_rounded, size: 18, color: Colors.redAccent),
                            onPressed: () {
                              setDialogState(() {
                                steps.removeAt(index);
                              });
                            },
                          ),
                          const Icon(Icons.drag_handle_rounded, size: 20, color: Colors.grey),
                        ],
                      ),
                    ),
                  );
                },
              ),

            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
                  ),
                  onPressed: () {
                    final title = titleCtrl.text.trim();
                    if (title.isEmpty) return;

                    final bonus = int.tryParse(bonusCtrl.text.trim()) ?? 25;
                    final quest = Quest(
                      id: existing?.id,
                      title: title,
                      description: descCtrl.text.trim(),
                      category: catCtrl.text.trim().isNotEmpty ? catCtrl.text.trim() : 'General Gauntlet',
                      bonusTokensOnComplete: bonus,
                      steps: steps,
                    );

                    Provider.of<QuestService>(context, listen: false).saveCustomQuest(quest);
                    Navigator.pop(dialogCtx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Saved quest "${quest.title}"!'), behavior: SnackBarBehavior.floating),
                    );
                  },
                  child: const Text('Save Quest'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  void _openExistingDirectivePicker({required Function(List<OrderItem>) onAddDirectives}) {
    final engine = Provider.of<OrderEngine>(context, listen: false);
    final allPacks = engine.packs;
    final Set<OrderItem> selected = {};
    String searchQuery = '';
    String? selectedPackFilter;

    DraggableDialog.show(
      context: context,
      title: 'Import Existing Directives',
      maxWidth: 620,
      builder: (pickerCtx, setPickerState) {
        final theme = Theme.of(pickerCtx);

        // Gather all orders
        List<OrderItem> allOrders = [];
        for (final pack in allPacks) {
          if (selectedPackFilter == null || pack.id == selectedPackFilter) {
            allOrders.addAll(pack.orders);
          }
        }

        // Apply search query
        final filteredOrders = allOrders.where((o) {
          if (searchQuery.isEmpty) return true;
          final q = searchQuery.toLowerCase();
          return o.title.toLowerCase().contains(q) ||
              o.description.toLowerCase().contains(q) ||
              o.category.toLowerCase().contains(q);
        }).toList();

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Search Bar & Filter
            Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'Search directives...',
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      border: const OutlineInputBorder(),
                      isDense: true,
                      suffixIcon: searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear_rounded, size: 18),
                              onPressed: () => setPickerState(() => searchQuery = ''),
                            )
                          : null,
                    ),
                    onChanged: (val) => setPickerState(() => searchQuery = val.trim()),
                  ),
                ),
                const SizedBox(width: 10),
                DropdownButton<String?>(
                  value: selectedPackFilter,
                  hint: const Text('All Packs', style: TextStyle(fontSize: 13)),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('All Packs')),
                    ...allPacks.map((p) => DropdownMenuItem<String?>(
                          value: p.id,
                          child: Text(
                            p.title.length > 18 ? '${p.title.substring(0, 18)}...' : p.title,
                            style: const TextStyle(fontSize: 13),
                          ),
                        )),
                  ],
                  onChanged: (val) => setPickerState(() => selectedPackFilter = val),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Selection Quick Actions
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'DIRECTIVES (${filteredOrders.length})',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                    color: theme.colorScheme.primary,
                  ),
                ),
                Row(
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                      onPressed: () {
                        setPickerState(() {
                          if (selected.length == filteredOrders.length) {
                            selected.clear();
                          } else {
                            selected.addAll(filteredOrders);
                          }
                        });
                      },
                      child: Text(
                        selected.length == filteredOrders.length ? 'Deselect All' : 'Select All',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 6),

            // Directives List
            if (filteredOrders.isEmpty)
              Container(
                padding: const EdgeInsets.all(24),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'No matching directives found.',
                  style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 13),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 340),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: filteredOrders.length,
                  itemBuilder: (context, index) {
                    final order = filteredOrders[index];
                    final isChecked = selected.contains(order);

                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      color: isChecked ? theme.colorScheme.primary.withOpacity(0.12) : null,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(
                          color: isChecked ? theme.colorScheme.primary : Colors.transparent,
                          width: 1.2,
                        ),
                      ),
                      child: CheckboxListTile(
                        value: isChecked,
                        dense: true,
                        activeColor: theme.colorScheme.primary,
                        title: Text(
                          order.title,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        subtitle: Text(
                          '${order.category} • ${order.formattedTiming} • +${order.rewardTokens} tk',
                          style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.7)),
                        ),
                        onChanged: (val) {
                          setPickerState(() {
                            if (val == true) {
                              selected.add(order);
                            } else {
                              selected.remove(order);
                            }
                          });
                        },
                      ),
                    );
                  },
                ),
              ),

            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(pickerCtx),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: Text('Add ${selected.length} to Quest'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
                  ),
                  onPressed: selected.isEmpty
                      ? null
                      : () {
                          onAddDirectives(selected.toList());
                          Navigator.pop(pickerCtx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Added ${selected.length} directive(s) to quest!'),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        },
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  void _openStepEditor({QuestStep? existing, required Function(QuestStep) onSave}) {
    final titleCtrl = TextEditingController(text: existing?.title ?? '');
    final descCtrl = TextEditingController(text: existing?.description ?? '');
    final narrativeCtrl = TextEditingController(text: existing?.narrativeText ?? '');
    final tokenCtrl = TextEditingController(text: '${existing?.rewardTokens ?? 5}');
    
    // Parse duration value and unit
    int durationValue = 2;
    String durationUnit = 'Minutes';

    if (existing != null) {
      if (existing.durationType == DurationType.actionTimer && existing.actionDurationSeconds > 0) {
        if (existing.actionDurationSeconds >= 3600 && existing.actionDurationSeconds % 3600 == 0) {
          durationValue = existing.actionDurationSeconds ~/ 3600;
          durationUnit = 'Hours';
        } else if (existing.actionDurationSeconds >= 60 && existing.actionDurationSeconds % 60 == 0) {
          durationValue = existing.actionDurationSeconds ~/ 60;
          durationUnit = 'Minutes';
        } else {
          durationValue = existing.actionDurationSeconds;
          durationUnit = 'Seconds';
        }
      } else if (existing.durationMinutes > 0) {
        if (existing.durationMinutes >= 60 && existing.durationMinutes % 60 == 0) {
          durationValue = existing.durationMinutes ~/ 60;
          durationUnit = 'Hours';
        } else {
          durationValue = existing.durationMinutes;
          durationUnit = 'Minutes';
        }
      }
    }

    DurationType durationType = existing?.durationType ?? DurationType.actionTimer;
    bool isMystery = existing?.isHiddenUntilUnlocked ?? false;

    DraggableDialog.show(
      context: context,
      title: existing != null ? 'Edit Step' : 'Add Quest Step',
      maxWidth: 500,
      builder: (dialogCtx, setDialogState) {
        final theme = Theme.of(dialogCtx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(
                labelText: 'Step Title *',
                hintText: 'e.g. Plank Hold Induction',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Step Directive Details',
                hintText: 'Describe the action or requirement...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: narrativeCtrl,
              decoration: const InputDecoration(
                labelText: 'Narrative Lore / Flavor Text (Optional)',
                hintText: 'e.g. You are ready to yield.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),

            // Clean, non-overlapping Timer & Duration Layout
            DropdownButtonFormField<DurationType>(
              value: durationType,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Timer / Duration Type',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: DurationType.instant, child: Text('Instant / Untimed')),
                DropdownMenuItem(value: DurationType.actionTimer, child: Text('Action Timer (Alarms on end)')),
                DropdownMenuItem(value: DurationType.deadlineCountdown, child: Text('Completion Deadline Countdown')),
              ],
              onChanged: (val) {
                if (val != null) setDialogState(() => durationType = val);
              },
            ),

            if (durationType != DurationType.instant) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      key: ValueKey('duration_val_${durationValue}_$durationUnit'),
                      initialValue: '$durationValue',
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: durationType == DurationType.actionTimer
                            ? 'Action Duration'
                            : 'Deadline Window',
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (val) => durationValue = int.tryParse(val) ?? 1,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<String>(
                      value: durationUnit,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Unit',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'Seconds', child: Text('Seconds')),
                        DropdownMenuItem(value: 'Minutes', child: Text('Minutes')),
                        DropdownMenuItem(value: 'Hours', child: Text('Hours')),
                      ],
                      onChanged: (val) {
                        if (val != null) setDialogState(() => durationUnit = val);
                      },
                    ),
                  ),
                ],
              ),
            ],

            const SizedBox(height: 12),
            TextField(
              controller: tokenCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Step Reward Tokens',
                prefixIcon: Icon(Icons.stars_rounded, color: Colors.amber),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            SwitchListTile(
              title: const Text('Mystery Fog-of-War Step', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              subtitle: const Text('Masks step details as "???" until previous step is completed.', style: TextStyle(fontSize: 11)),
              value: isMystery,
              onChanged: (v) => setDialogState(() => isMystery = v),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('Cancel')),
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
                  ),
                  onPressed: () {
                    final title = titleCtrl.text.trim();
                    if (title.isEmpty) return;
                    final tokens = int.tryParse(tokenCtrl.text.trim()) ?? 5;

                    int computedActionSecs = 0;
                    int computedDeadlineMins = 0;

                    if (durationUnit == 'Seconds') {
                      computedActionSecs = durationValue;
                      computedDeadlineMins = (durationValue / 60).ceil().clamp(1, 99999);
                    } else if (durationUnit == 'Minutes') {
                      computedActionSecs = durationValue * 60;
                      computedDeadlineMins = durationValue;
                    } else if (durationUnit == 'Hours') {
                      computedActionSecs = durationValue * 3600;
                      computedDeadlineMins = durationValue * 60;
                    }

                    final step = QuestStep(
                      id: existing?.id,
                      orderIndex: existing?.orderIndex ?? 1,
                      title: title,
                      description: descCtrl.text.trim(),
                      narrativeText: narrativeCtrl.text.trim().isNotEmpty ? narrativeCtrl.text.trim() : null,
                      durationType: durationType,
                      durationMinutes: computedDeadlineMins,
                      actionDurationSeconds: computedActionSecs,
                      rewardTokens: tokens,
                      isHiddenUntilUnlocked: isMystery,
                    );
                    onSave(step);
                    Navigator.pop(dialogCtx);
                  },
                  child: const Text('Done'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  void _dispatchQuest(Quest quest) {
    final partnerSvc = Provider.of<PartnerService>(context, listen: false);
    final sync = Provider.of<SyncService>(context, listen: false);
    final contacts = partnerSvc.unblockedContacts;

    showDialog(
      context: context,
      builder: (ctx) {
        PartnerContact? selectedPartner = partnerSvc.activePartner;

        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            final theme = Theme.of(dialogCtx);

            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              title: const Row(
                children: [
                  Icon(Icons.send_rounded, color: Colors.purpleAccent),
                  SizedBox(width: 10),
                  Text('Dispatch Quest Playlist'),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Dispatch "${quest.title}" (${quest.steps.length} steps) to your submissive:',
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 16),
                  if (contacts.isEmpty)
                    const Text('No paired partners found. Will broadcast to paired channel.')
                  else
                    DropdownButtonFormField<PartnerContact>(
                      value: selectedPartner,
                      decoration: const InputDecoration(labelText: 'Select Recipient', border: OutlineInputBorder()),
                      items: contacts.map((c) => DropdownMenuItem(
                        value: c,
                        child: Text('${c.displayName} (${c.pairingCode})'),
                      )).toList(),
                      onChanged: (val) => setDialogState(() => selectedPartner = val),
                    ),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                ElevatedButton.icon(
                  icon: const Icon(Icons.send_rounded, size: 16),
                  label: const Text('Dispatch Quest'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
                  ),
                  onPressed: () {
                    sync.dispatchQuestToPlayer(quest, targetPartner: selectedPartner);
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Dispatched quest "${quest.title}" to ${selectedPartner?.displayName ?? "Player"}!'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _sanitizeFileName(String title) {
    return title.toLowerCase().trim().replaceAll(RegExp(r'[^a-z0-9_]'), '_');
  }

  void _sendQuestViaChat(Quest quest) {
    final partnerSvc = Provider.of<PartnerService>(context, listen: false);
    final sync = Provider.of<SyncService>(context, listen: false);
    final contacts = partnerSvc.unblockedContacts;

    if (contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No paired partners found to send quest.')),
      );
      return;
    }

    PartnerContact? selectedPartner = partnerSvc.activePartner ?? contacts.first;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.send_rounded, color: Colors.purpleAccent),
              const SizedBox(width: 10),
              Expanded(child: Text('Send "${quest.title}" in Chat', overflow: TextOverflow.ellipsis)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Send this quest (${quest.steps.length} steps) to:'),
              const SizedBox(height: 12),
              DropdownButtonFormField<PartnerContact>(
                value: selectedPartner,
                decoration: const InputDecoration(labelText: 'Recipient', border: OutlineInputBorder()),
                items: contacts.map((c) => DropdownMenuItem(value: c, child: Text('${c.displayName} (${c.pairingCode})'))).toList(),
                onChanged: (val) => setDialogState(() => selectedPartner = val),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton.icon(
              icon: const Icon(Icons.send_rounded, size: 16),
              label: const Text('Send Quest'),
              onPressed: selectedPartner == null ? null : () async {
                Navigator.pop(ctx);
                final rawJson = jsonEncode(quest.toJson());
                await sync.sendChatMessage(
                  selectedPartner!,
                  'Shared Quest: "${quest.title}" (${quest.steps.length} steps)',
                  packType: 'quest',
                  packTitle: quest.title,
                  packItemCount: quest.steps.length,
                  packData: rawJson,
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Sent quest "${quest.title}" to ${selectedPartner!.displayName}!'), behavior: SnackBarBehavior.floating),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _sendQuestPackViaChat(QuestPack pack) {
    final partnerSvc = Provider.of<PartnerService>(context, listen: false);
    final sync = Provider.of<SyncService>(context, listen: false);
    final contacts = partnerSvc.unblockedContacts;

    if (contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No paired partners found to send quest pack.')),
      );
      return;
    }

    PartnerContact? selectedPartner = partnerSvc.activePartner ?? contacts.first;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.auto_stories_rounded, color: Colors.purpleAccent),
              const SizedBox(width: 10),
              Expanded(child: Text('Send "${pack.title}" in Chat', overflow: TextOverflow.ellipsis)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Send this quest pack (${pack.quests.length} quests, ${pack.totalStepsCount} steps) to:'),
              const SizedBox(height: 12),
              DropdownButtonFormField<PartnerContact>(
                value: selectedPartner,
                decoration: const InputDecoration(labelText: 'Recipient', border: OutlineInputBorder()),
                items: contacts.map((c) => DropdownMenuItem(value: c, child: Text('${c.displayName} (${c.pairingCode})'))).toList(),
                onChanged: (val) => setDialogState(() => selectedPartner = val),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton.icon(
              icon: const Icon(Icons.send_rounded, size: 16),
              label: const Text('Send Pack'),
              onPressed: selectedPartner == null ? null : () async {
                Navigator.pop(ctx);
                final rawJson = jsonEncode(pack.toJson());
                await sync.sendChatMessage(
                  selectedPartner!,
                  'Shared Quest Pack: "${pack.title}" (${pack.quests.length} quests)',
                  packType: 'questPack',
                  packTitle: pack.title,
                  packItemCount: pack.quests.length,
                  packData: rawJson,
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Sent "${pack.title}" to ${selectedPartner!.displayName}!'), behavior: SnackBarBehavior.floating),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _exportQuest(Quest quest) {
    final questSvc = Provider.of<QuestService>(context, listen: false);
    final rawJson = jsonEncode(quest.toJson());
    final passCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('Export "${quest.title}"'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Export as a standalone .questpack file. You can optionally protect it with a password:'),
              const SizedBox(height: 14),
              const Text('Encryption Password (Optional)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              TextField(
                controller: passCtrl,
                obscureText: true,
                decoration: const InputDecoration(hintText: 'Leave empty for unencrypted file'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            OutlinedButton.icon(
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: const Text('Clipboard'),
              onPressed: () {
                final output = questSvc.exportQuest(quest, passCtrl.text.trim());
                Clipboard.setData(ClipboardData(text: output));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Quest copied to clipboard!'), behavior: SnackBarBehavior.floating),
                );
              },
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.save_alt_rounded, size: 18),
              label: const Text('Save to File'),
              onPressed: () async {
                final output = questSvc.exportQuest(quest, passCtrl.text.trim());
                Navigator.pop(ctx);

                try {
                  final defaultFileName = '${_sanitizeFileName(quest.title)}.questpack';
                  final savedUri = await FilePicker.saveFile(
                    dialogTitle: 'Save Quest File',
                    fileName: defaultFileName,
                    bytes: utf8.encode(output),
                    type: FileType.custom,
                    allowedExtensions: ['questpack', 'json'],
                  );

                  if (savedUri != null && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Saved quest file: $defaultFileName'), behavior: SnackBarBehavior.floating),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error saving file: $e')));
                  }
                }
              },
            ),
          ],
        );
      },
    );
  }

  void _exportQuestPack(QuestPack pack) {
    final questSvc = Provider.of<QuestService>(context, listen: false);
    final passCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('Export Quest Pack "${pack.title}"'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Export ${pack.quests.length} chained quests as a .questpack file:'),
              const SizedBox(height: 14),
              const Text('Encryption Password (Optional)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              TextField(
                controller: passCtrl,
                obscureText: true,
                decoration: const InputDecoration(hintText: 'Leave empty for unencrypted file'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            OutlinedButton.icon(
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: const Text('Clipboard'),
              onPressed: () {
                final output = questSvc.exportQuestPack(pack, passCtrl.text.trim());
                Clipboard.setData(ClipboardData(text: output));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Quest pack copied to clipboard!'), behavior: SnackBarBehavior.floating),
                );
              },
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.save_alt_rounded, size: 18),
              label: const Text('Save to File'),
              onPressed: () async {
                final output = questSvc.exportQuestPack(pack, passCtrl.text.trim());
                Navigator.pop(ctx);

                try {
                  final defaultFileName = '${_sanitizeFileName(pack.title)}.questpack';
                  final savedUri = await FilePicker.saveFile(
                    dialogTitle: 'Save Quest Pack File',
                    fileName: defaultFileName,
                    bytes: utf8.encode(output),
                    type: FileType.custom,
                    allowedExtensions: ['questpack', 'json'],
                  );

                  if (savedUri != null && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Saved quest pack: $defaultFileName'), behavior: SnackBarBehavior.floating),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error saving file: $e')));
                  }
                }
              },
            ),
          ],
        );
      },
    );
  }

  void _openQuestPackCraftingDialog([QuestPack? existing]) {
    final questSvc = Provider.of<QuestService>(context, listen: false);
    final allQuests = questSvc.allQuests;
    final titleCtrl = TextEditingController(text: existing?.title ?? '');
    final descCtrl = TextEditingController(text: existing?.description ?? '');
    final authorCtrl = TextEditingController(text: existing?.author ?? 'Director');
    final versionCtrl = TextEditingController(text: existing?.version ?? '1.0.0');

    final selectedQuestIds = existing != null
        ? existing.quests.map((q) => q.id).toSet()
        : <String>{};

    DraggableDialog.show(
      context: context,
      title: existing != null ? 'Edit Quest Pack' : 'Craft New Quest Pack',
      maxWidth: 550,
      builder: (dialogCtx, setDialogState) {
        final theme = Theme.of(dialogCtx);

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(
                labelText: 'Quest Pack Title *',
                hintText: 'e.g. Master Discipline Gauntlet',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Description / Purpose',
                hintText: 'Overview of this multi-quest playlist collection...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: authorCtrl,
                    decoration: const InputDecoration(labelText: 'Author / Creator', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: versionCtrl,
                    decoration: const InputDecoration(labelText: 'Version', border: OutlineInputBorder()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'SELECT QUESTS TO BUNDLE (${selectedQuestIds.length}/${allQuests.length}):',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.1, color: theme.colorScheme.primary),
            ),
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: theme.colorScheme.outlineVariant.withOpacity(0.4)),
              ),
              child: allQuests.isEmpty
                  ? const Center(child: Padding(padding: EdgeInsets.all(16), child: Text('No quests created yet.')))
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: allQuests.length,
                      itemBuilder: (context, idx) {
                        final q = allQuests[idx];
                        final isSelected = selectedQuestIds.contains(q.id);
                        return CheckboxListTile(
                          dense: true,
                          value: isSelected,
                          title: Text(q.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text('${q.steps.length} Steps • ${q.category} • +${q.totalPotentialTokens} Tok'),
                          secondary: IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            tooltip: 'Edit Quest',
                            onPressed: () => _openQuestEditor(q),
                          ),
                          onChanged: (val) {
                            setDialogState(() {
                              if (val == true) {
                                selectedQuestIds.add(q.id);
                              } else {
                                selectedQuestIds.remove(q.id);
                              }
                            });
                          },
                        );
                      },
                    ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('Cancel')),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  icon: const Icon(Icons.check_rounded, size: 16),
                  label: const Text('Save Quest Pack'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
                  ),
                  onPressed: () async {
                    final title = titleCtrl.text.trim();
                    if (title.isEmpty) return;
                    if (selectedQuestIds.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please select at least 1 quest for this pack.')),
                      );
                      return;
                    }

                    final bundledQuests = allQuests.where((q) => selectedQuestIds.contains(q.id)).toList();
                    final pack = QuestPack(
                      id: existing?.id,
                      title: title,
                      description: descCtrl.text.trim(),
                      author: authorCtrl.text.trim().isNotEmpty ? authorCtrl.text.trim() : 'Director',
                      version: versionCtrl.text.trim().isNotEmpty ? versionCtrl.text.trim() : '1.0.0',
                      quests: bundledQuests,
                    );

                    await questSvc.saveQuestPack(pack);
                    Navigator.pop(dialogCtx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Saved Quest Pack "${pack.title}" with ${pack.quests.length} quests!'), behavior: SnackBarBehavior.floating),
                    );
                  },
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  void _importQuestOrPack(BuildContext context) {
    final questSvc = Provider.of<QuestService>(context, listen: false);
    final dataCtrl = TextEditingController();
    final passCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.file_open_outlined, color: Colors.purpleAccent),
              SizedBox(width: 10),
              Text('Import Quest or Pack'),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Import a standalone Quest or multi-quest playlist pack:'),
                const SizedBox(height: 12),
                Center(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.folder_open_rounded),
                    label: const Text('Pick .questpack File'),
                    onPressed: () async {
                      try {
                        final result = await FilePicker.pickFiles(
                          type: FileType.custom,
                          allowedExtensions: ['questpack', 'json', 'txt'],
                        );

                        if (result != null && result.isNotEmpty && result.single.path != null) {
                          final file = File(result.single.path!);
                          final rawContent = await file.readAsString();
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (context.mounted) {
                            _processImportData(context, questSvc, rawContent);
                          }
                        }
                      } catch (e) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Failed to read file: $e')),
                        );
                      }
                    },
                  ),
                ),
                const SizedBox(height: 16),
                const Row(
                  children: [
                    Expanded(child: Divider()),
                    Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('OR PASTE TEXT', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold))),
                    Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: dataCtrl,
                  maxLines: 4,
                  decoration: const InputDecoration(hintText: 'Paste Quest / Pack JSON or encrypted payload...', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: passCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password (If encrypted)', border: OutlineInputBorder()),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final raw = dataCtrl.text.trim();
                if (raw.isEmpty) return;
                Navigator.pop(ctx);
                _processImportData(context, questSvc, raw, passCtrl.text.trim());
              },
              child: const Text('Import Text'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _processImportData(BuildContext context, QuestService questSvc, String raw, [String? password]) async {
    try {
      final res = await questSvc.importQuestFromJson(raw, password);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Successfully imported "${res.title}"!'), behavior: SnackBarBehavior.floating),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: Check password or JSON format ($e)')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final questSvc = Provider.of<QuestService>(context);
    final allQuests = questSvc.allQuests;
    final questPacks = questSvc.questPacks;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Director Quest Studio'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_open_outlined),
            tooltip: 'Import Quest or Pack (.questpack)',
            onPressed: () => _importQuestOrPack(context),
          ),
          IconButton(
            icon: const Icon(Icons.library_add_rounded),
            tooltip: 'Craft New Quest Pack',
            onPressed: () => _openQuestPackCraftingDialog(),
          ),
          IconButton(
            icon: const Icon(Icons.add_rounded),
            tooltip: 'Create New Quest',
            onPressed: () => _openQuestEditor(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Header Card
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Icon(Icons.hub_rounded, size: 36, color: theme.colorScheme.primary),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Chained Directive Playlists & Packs',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Craft individual quest chains or bundle them into full packs to share seamlessly via encrypted chat.',
                          style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.7)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.library_add_rounded, size: 16),
                    label: const Text('Craft Pack'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.purpleAccent,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () => _openQuestPackCraftingDialog(),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),

          // Crafted Quest Packs Section
          if (questPacks.isNotEmpty) ...[
            Text(
              'CRAFTED QUEST PACKS (${questPacks.length})',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
                color: Colors.purpleAccent,
              ),
            ),
            const SizedBox(height: 8),
            ...questPacks.map((pack) => Card(
              margin: const EdgeInsets.symmetric(vertical: 6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: Colors.purpleAccent.withOpacity(0.4), width: 1.2),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.auto_stories_rounded, size: 20, color: Colors.purpleAccent),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            pack.title,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.purpleAccent.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'v${pack.version}',
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.purpleAccent),
                          ),
                        ),
                      ],
                    ),
                    if (pack.description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(pack.description, style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withOpacity(0.7))),
                    ],
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Text(
                          '${pack.quests.length} Quests  •  ${pack.totalStepsCount} Steps  •  +${pack.totalPotentialTokens} Tokens  •  by ${pack.author}',
                          style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.7)),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.send_rounded, size: 18, color: Colors.purpleAccent),
                          tooltip: 'Send Pack via Chat',
                          onPressed: () => _sendQuestPackViaChat(pack),
                        ),
                        IconButton(
                          icon: const Icon(Icons.file_download_outlined, size: 20),
                          tooltip: 'Export Quest Pack (.questpack)',
                          onPressed: () => _exportQuestPack(pack),
                        ),
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          tooltip: 'Edit Quest Pack',
                          onPressed: () => _openQuestPackCraftingDialog(pack),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline_rounded, size: 20, color: Colors.redAccent),
                          tooltip: 'Delete Pack',
                          onPressed: () => questSvc.deleteQuestPack(pack.id),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            )),
            const SizedBox(height: 20),
          ],

          Text(
            'QUEST PLAYLISTS (${allQuests.length})',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 8),

          ...allQuests.map((q) => Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
                          q.category.toUpperCase(),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (q.isPreset)
                        const Chip(
                          visualDensity: VisualDensity.compact,
                          label: Text('PRESET', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold)),
                        ),
                      const Spacer(),
                      Row(
                        children: [
                          const Icon(Icons.stars_rounded, size: 16, color: Colors.amber),
                          const SizedBox(width: 4),
                          Text(
                            '+${q.totalPotentialTokens} Total Tokens',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.amber),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    q.title,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    q.description,
                    style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withOpacity(0.7)),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(Icons.format_list_numbered_rounded, size: 16, color: theme.colorScheme.onSurface.withOpacity(0.6)),
                      const SizedBox(width: 6),
                      Text(
                        '${q.steps.length} Steps',
                        style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.7)),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.send_rounded, size: 18, color: Colors.cyanAccent),
                        tooltip: 'Send Quest via Chat',
                        onPressed: () => _sendQuestViaChat(q),
                      ),
                      IconButton(
                        icon: const Icon(Icons.file_download_outlined, size: 20),
                        tooltip: 'Export Quest (.questpack)',
                        onPressed: () => _exportQuest(questSvc.allQuests.firstWhere((item) => item.id == q.id)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        tooltip: q.isPreset ? 'Customize / Edit Quest' : 'Edit Quest',
                        onPressed: () => _openQuestEditor(q),
                      ),
                      if (!q.isPreset)
                        IconButton(
                          icon: const Icon(Icons.delete_outline_rounded, size: 20, color: Colors.redAccent),
                          tooltip: 'Delete Quest',
                          onPressed: () => questSvc.deleteCustomQuest(q.id),
                        ),
                      const SizedBox(width: 6),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.play_arrow_rounded, size: 16),
                        label: const Text('Dispatch'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.purpleAccent,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () => _dispatchQuest(q),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          )),
        ],
      ),
    );
  }
}
