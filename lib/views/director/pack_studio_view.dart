import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/order_pack.dart';
import '../../models/order_item.dart';
import '../../services/order_engine.dart';
import '../../widgets/draggable_dialog.dart';

class PackStudioView extends StatefulWidget {
  final OrderPack? existingPack;

  const PackStudioView({super.key, this.existingPack});

  @override
  State<PackStudioView> createState() => _PackStudioViewState();
}

class _PackStudioViewState extends State<PackStudioView> {
  late TextEditingController _titleController;
  late TextEditingController _descController;
  late TextEditingController _authorController;
  late List<OrderItem> _orders;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.existingPack?.title ?? '');
    _descController = TextEditingController(text: widget.existingPack?.description ?? '');
    _authorController = TextEditingController(text: widget.existingPack?.author ?? 'Director');
    _orders = widget.existingPack != null
        ? List<OrderItem>.from(widget.existingPack!.orders)
        : [];
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descController.dispose();
    _authorController.dispose();
    super.dispose();
  }

  Widget _buildFieldLabel(String label, BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          color: theme.colorScheme.onSurface.withOpacity(0.8),
        ),
      ),
    );
  }

  void _showAddEditOrderDialog([OrderItem? existingOrder, int? index]) {
    final titleCtrl = TextEditingController(text: existingOrder?.title ?? '');
    final descCtrl = TextEditingController(text: existingOrder?.description ?? '');
    final catCtrl = TextEditingController(text: existingOrder?.category ?? 'General');
    final equipmentCtrl = TextEditingController(
      text: existingOrder?.requiredEquipment.join(', ') ?? '',
    );
    int tier = existingOrder?.tier ?? 1;
    DurationType durationType = existingOrder?.durationType ?? DurationType.instant;
    int rawActionSecs = existingOrder?.actionDurationSeconds ?? 120;
    int actionValue;
    String actionUnit;
    if (rawActionSecs >= 3600 && rawActionSecs % 3600 == 0) {
      actionValue = rawActionSecs ~/ 3600;
      actionUnit = 'Hours';
    } else if (rawActionSecs >= 60 && rawActionSecs % 60 == 0) {
      actionValue = rawActionSecs ~/ 60;
      actionUnit = 'Minutes';
    } else {
      actionValue = rawActionSecs > 0 ? rawActionSecs : 120;
      actionUnit = 'Seconds';
    }

    int rawDeadlineMins = existingOrder?.durationMinutes ?? 15;
    int deadlineValue;
    String deadlineUnit;
    if (rawDeadlineMins >= 60 && rawDeadlineMins % 60 == 0) {
      deadlineValue = rawDeadlineMins ~/ 60;
      deadlineUnit = 'Hours';
    } else {
      deadlineValue = rawDeadlineMins > 0 ? rawDeadlineMins : 15;
      deadlineUnit = 'Minutes';
    }

    int cooldownHours = existingOrder?.cooldownHours ?? 0;
    VerificationType verificationType = existingOrder?.verificationType ?? VerificationType.honorCheck;
    int rewardTokens = existingOrder?.rewardTokens ?? 10;
    int penaltyTokens = existingOrder?.penaltyTokens ?? 20;
    bool allowRandomDraw = existingOrder?.allowRandomDraw ?? true;

    DraggableDialog.show(
      context: context,
      title: existingOrder != null ? 'Edit Directive' : 'New Directive',
      maxWidth: 640,
      hasUnsavedChanges: () {
        if (existingOrder == null) {
          return titleCtrl.text.trim().isNotEmpty ||
              descCtrl.text.trim().isNotEmpty ||
              (catCtrl.text.trim().isNotEmpty && catCtrl.text.trim() != 'General') ||
              equipmentCtrl.text.trim().isNotEmpty;
        }
        if (titleCtrl.text.trim() != existingOrder.title.trim()) return true;
        if (descCtrl.text.trim() != existingOrder.description.trim()) return true;
        if (catCtrl.text.trim() != existingOrder.category.trim()) return true;
        if (equipmentCtrl.text.trim() != existingOrder.requiredEquipment.join(', ').trim()) return true;
        if (tier != existingOrder.tier) return true;
        if (durationType != existingOrder.durationType) return true;
        if (verificationType != existingOrder.verificationType) return true;
        if (rewardTokens != existingOrder.rewardTokens) return true;
        if (penaltyTokens != existingOrder.penaltyTokens) return true;
        if (allowRandomDraw != existingOrder.allowRandomDraw) return true;

        int computedActionSecs = actionValue;
        if (actionUnit == 'Hours') computedActionSecs = actionValue * 3600;
        if (actionUnit == 'Minutes') computedActionSecs = actionValue * 60;
        if (computedActionSecs != existingOrder.actionDurationSeconds) return true;

        int computedDeadlineMins = deadlineValue;
        if (deadlineUnit == 'Hours') computedDeadlineMins = deadlineValue * 60;
        if (deadlineUnit == 'Seconds') computedDeadlineMins = (deadlineValue / 60).ceil().clamp(1, 999999);
        if (computedDeadlineMins != existingOrder.durationMinutes) return true;

        return false;
      },
      builder: (ctx, setModalState) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildFieldLabel('Directive Title', context),
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(hintText: 'e.g. Posture Alignment'),
            ),
            const SizedBox(height: 14),
            _buildFieldLabel('Description / Instructions', context),
            TextField(
              controller: descCtrl,
              maxLines: 2,
              decoration: const InputDecoration(hintText: 'Detailed requirements or parameters...'),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildFieldLabel('Category', context),
                      TextField(
                        controller: catCtrl,
                        decoration: const InputDecoration(hintText: 'e.g. Focus, Discipline'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildFieldLabel('Difficulty Tier', context),
                      DropdownButtonFormField<int>(
                        value: tier,
                        decoration: const InputDecoration(),
                        items: [1, 2, 3, 4, 5]
                            .map((t) => DropdownMenuItem(value: t, child: Text('Tier $t')))
                            .toList(),
                        onChanged: (val) {
                          if (val != null) setModalState(() => tier = val);
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _buildFieldLabel('Timing Model', context),
            DropdownButtonFormField<DurationType>(
              value: durationType,
              decoration: const InputDecoration(),
              items: const [
                DropdownMenuItem(value: DurationType.instant, child: Text('Instant / Untimed')),
                DropdownMenuItem(value: DurationType.actionTimer, child: Text('Action Routine Timer (Alarms on end)')),
                DropdownMenuItem(value: DurationType.deadlineCountdown, child: Text('Completion Deadline Countdown')),
                DropdownMenuItem(value: DurationType.actionWithDeadline, child: Text('Action Timer + Completion Deadline')),
                DropdownMenuItem(value: DurationType.dailyWindow, child: Text('End of Day Window')),
              ],
              onChanged: (val) {
                if (val != null) setModalState(() => durationType = val);
              },
            ),
            if (durationType == DurationType.actionTimer || durationType == DurationType.actionWithDeadline) ...[
              const SizedBox(height: 14),
              _buildFieldLabel('Action Routine Duration', context),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      key: ValueKey('action_val_$actionValue'),
                      initialValue: '$actionValue',
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(hintText: 'e.g. 2'),
                      onChanged: (val) => actionValue = int.tryParse(val) ?? 1,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<String>(
                      value: actionUnit,
                      decoration: const InputDecoration(),
                      items: const [
                        DropdownMenuItem(value: 'Seconds', child: Text('Seconds')),
                        DropdownMenuItem(value: 'Minutes', child: Text('Minutes')),
                        DropdownMenuItem(value: 'Hours', child: Text('Hours')),
                      ],
                      onChanged: (val) {
                        if (val != null) setModalState(() => actionUnit = val);
                      },
                    ),
                  ),
                ],
              ),
            ],
            if (durationType == DurationType.deadlineCountdown || durationType == DurationType.actionWithDeadline) ...[
              const SizedBox(height: 14),
              _buildFieldLabel('Completion Deadline Window', context),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      key: ValueKey('deadline_val_$deadlineValue'),
                      initialValue: '$deadlineValue',
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(hintText: 'e.g. 30'),
                      onChanged: (val) => deadlineValue = int.tryParse(val) ?? 1,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<String>(
                      value: deadlineUnit,
                      decoration: const InputDecoration(),
                      items: const [
                        DropdownMenuItem(value: 'Seconds', child: Text('Seconds')),
                        DropdownMenuItem(value: 'Minutes', child: Text('Minutes')),
                        DropdownMenuItem(value: 'Hours', child: Text('Hours')),
                      ],
                      onChanged: (val) {
                        if (val != null) setModalState(() => deadlineUnit = val);
                      },
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            _buildFieldLabel('Verification Required', context),
            DropdownButtonFormField<VerificationType>(
              value: verificationType,
              decoration: const InputDecoration(),
              items: const [
                DropdownMenuItem(value: VerificationType.honorCheck, child: Text('Honor')),
                DropdownMenuItem(value: VerificationType.noteProof, child: Text('Note')),
                DropdownMenuItem(value: VerificationType.photoProof, child: Text('Photo Proof')),
                DropdownMenuItem(value: VerificationType.timerOnly, child: Text('Timer Only')),
              ],
              onChanged: (val) {
                if (val != null) setModalState(() => verificationType = val);
              },
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildFieldLabel('Reward Tokens (+)', context),
                      TextFormField(
                        initialValue: '$rewardTokens',
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(hintText: '10'),
                        onChanged: (val) => rewardTokens = int.tryParse(val) ?? 10,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildFieldLabel('Penalty Tokens (-)', context),
                      TextFormField(
                        initialValue: '$penaltyTokens',
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(hintText: '20'),
                        onChanged: (val) => penaltyTokens = int.tryParse(val) ?? 20,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _buildFieldLabel('Required Equipment / Items (Comma separated)', context),
            TextField(
              controller: equipmentCtrl,
              decoration: const InputDecoration(
                hintText: 'e.g. Vibrator, Cage, Blindfold (or leave empty)',
              ),
            ),
            const SizedBox(height: 14),
            Card(
              child: SwitchListTile(
                secondary: Icon(
                  allowRandomDraw ? Icons.casino_rounded : Icons.lock_clock_rounded,
                  color: allowRandomDraw ? Theme.of(context).colorScheme.primary : Colors.grey,
                ),
                title: const Text('Include in Random Draws', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                subtitle: Text(
                  allowRandomDraw
                      ? 'Enabled: Can be randomly drawn from the deck.'
                      : 'Disabled: Manual assignment only (excluded from random draws).',
                  style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
                ),
                value: allowRandomDraw,
                onChanged: (val) => setModalState(() => allowRandomDraw = val),
              ),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  if (titleCtrl.text.trim().isEmpty) return;

                  final eqList = equipmentCtrl.text
                      .split(',')
                      .map((e) => e.trim())
                      .where((e) => e.isNotEmpty)
                      .toList();

                  int computedActionSecs = actionValue;
                  if (actionUnit == 'Hours') computedActionSecs = actionValue * 3600;
                  if (actionUnit == 'Minutes') computedActionSecs = actionValue * 60;

                  int computedDeadlineMins = deadlineValue;
                  if (deadlineUnit == 'Hours') computedDeadlineMins = deadlineValue * 60;
                  if (deadlineUnit == 'Seconds') computedDeadlineMins = (deadlineValue / 60).ceil().clamp(1, 999999);

                  final order = OrderItem(
                    id: existingOrder?.id,
                    title: titleCtrl.text.trim(),
                    description: descCtrl.text.trim(),
                    category: catCtrl.text.trim().isEmpty ? 'General' : catCtrl.text.trim(),
                    tier: tier,
                    durationType: durationType,
                    actionDurationSeconds: computedActionSecs,
                    durationMinutes: computedDeadlineMins,
                    cooldownHours: cooldownHours,
                    verificationType: verificationType,
                    rewardTokens: rewardTokens,
                    penaltyTokens: penaltyTokens,
                    allowRandomDraw: allowRandomDraw,
                    requiredEquipment: eqList,
                  );

                  setState(() {
                    if (index != null) {
                      _orders[index] = order;
                    } else {
                      _orders.add(order);
                    }
                  });
                  Navigator.pop(ctx);
                },
                child: Text(existingOrder != null ? 'Update Directive' : 'Add Directive'),
              ),
            ),
          ],
        );
      },
    );
  }

  bool _hasUnsavedChanges() {
    if (widget.existingPack == null) {
      return _titleController.text.trim().isNotEmpty ||
          _descController.text.trim().isNotEmpty ||
          _orders.isNotEmpty;
    }
    final p = widget.existingPack!;
    if (_titleController.text.trim() != p.title.trim()) return true;
    if (_descController.text.trim() != p.description.trim()) return true;
    if (_authorController.text.trim() != p.author.trim()) return true;
    if (_orders.length != p.orders.length) return true;
    for (int i = 0; i < _orders.length; i++) {
      if (_orders[i].id != p.orders[i].id ||
          _orders[i].title != p.orders[i].title ||
          _orders[i].description != p.orders[i].description ||
          _orders[i].tier != p.orders[i].tier ||
          _orders[i].durationType != p.orders[i].durationType ||
          _orders[i].actionDurationSeconds != p.orders[i].actionDurationSeconds ||
          _orders[i].durationMinutes != p.orders[i].durationMinutes ||
          _orders[i].verificationType != p.orders[i].verificationType ||
          _orders[i].rewardTokens != p.orders[i].rewardTokens ||
          _orders[i].penaltyTokens != p.orders[i].penaltyTokens ||
          _orders[i].allowRandomDraw != p.orders[i].allowRandomDraw ||
          _orders[i].category != p.orders[i].category ||
          _orders[i].requiredEquipment.join(',') != p.orders[i].requiredEquipment.join(',')) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _onWillPop() async {
    if (!_hasUnsavedChanges()) return true;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: const Text('Unsaved Changes'),
          content: const Text(
            'You have unsaved changes in this pack. Would you like to save your changes before exiting?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('Cancel'),
            ),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.redAccent,
              ),
              onPressed: () => Navigator.pop(ctx, 'discard'),
              child: const Text('Exit without Saving'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
              ),
              onPressed: () => Navigator.pop(ctx, 'save'),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (result == 'save') {
      final saved = _savePack(popAfterSave: false);
      return saved;
    } else if (result == 'discard') {
      return true;
    }
    return false;
  }

  bool _savePack({bool popAfterSave = true}) {
    if (_titleController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a pack title')),
      );
      return false;
    }

    final engine = Provider.of<OrderEngine>(context, listen: false);
    final pack = OrderPack(
      id: widget.existingPack?.id,
      title: _titleController.text.trim(),
      description: _descController.text.trim(),
      author: _authorController.text.trim().isEmpty ? 'Director' : _authorController.text.trim(),
      orders: _orders,
      createdAt: widget.existingPack?.createdAt ?? DateTime.now(),
      isEnabled: widget.existingPack?.isEnabled ?? true,
    );

    if (widget.existingPack != null) {
      engine.updatePack(pack);
    } else {
      engine.addPack(pack);
    }

    if (popAfterSave && context.mounted) {
      Navigator.pop(context);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Pack saved successfully!')),
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.existingPack != null ? 'Edit Pack' : 'Create Custom Pack'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              final shouldPop = await _onWillPop();
              if (shouldPop && context.mounted) {
                Navigator.pop(context);
              }
            },
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.check_rounded),
              onPressed: () => _savePack(),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildFieldLabel('Pack Title', context),
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(
              hintText: 'e.g. Physical Posture & Wellness',
            ),
          ),
          const SizedBox(height: 16),
          _buildFieldLabel('Pack Description', context),
          TextField(
            controller: _descController,
            maxLines: 2,
            decoration: const InputDecoration(
              hintText: 'e.g. Posture checks, hydration, and stretching routines.',
            ),
          ),
          const SizedBox(height: 16),
          _buildFieldLabel('Author / Director Name', context),
          TextField(
            controller: _authorController,
            decoration: const InputDecoration(
              hintText: 'e.g. Director or System',
            ),
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              Text(
                'DIRECTIVES (${_orders.length})',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 1.0),
              ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: () => _showAddEditOrderDialog(),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add Directive'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_orders.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    'No directives in this pack yet. Tap "Add Directive" above.',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5)),
                  ),
                ),
              ),
            )
          else
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: _orders.length,
              onReorder: (oldIndex, newIndex) {
                setState(() {
                  if (oldIndex < newIndex) {
                    newIndex -= 1;
                  }
                  final item = _orders.removeAt(oldIndex);
                  _orders.insert(newIndex, item);
                });
              },
              itemBuilder: (context, idx) {
                final item = _orders[idx];
                return Card(
                  key: ValueKey(item.id),
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: ReorderableDragStartListener(
                      index: idx,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                        child: const Icon(Icons.drag_indicator_rounded, color: Colors.grey),
                      ),
                    ),
                    title: Text(item.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 6,
                          children: [
                            Text('${item.category} • Tier ${item.tier} • +${item.rewardTokens} / -${item.penaltyTokens}'),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: item.allowRandomDraw
                                    ? Colors.cyanAccent.withOpacity(0.15)
                                    : Colors.grey.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    item.allowRandomDraw ? Icons.casino_rounded : Icons.lock_clock_rounded,
                                    size: 10,
                                    color: item.allowRandomDraw ? Colors.cyanAccent : Colors.grey,
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    item.allowRandomDraw ? 'Random Pool' : 'Manual Only',
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                      color: item.allowRandomDraw ? Colors.cyanAccent : Colors.grey,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (item.requiredEquipment.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Icon(Icons.inventory_2_outlined, size: 12, color: Colors.cyanAccent),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  'Requires: ${item.requiredEquipment.join(", ")}',
                                  style: const TextStyle(fontSize: 11, color: Colors.cyanAccent),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Tooltip(
                          message: item.allowRandomDraw
                              ? 'Random Draw: Enabled (Tap to exclude from random draws)'
                              : 'Random Draw: Disabled (Tap to include in random draws)',
                          child: Switch(
                            value: item.allowRandomDraw,
                            activeColor: Colors.cyanAccent,
                            onChanged: (val) {
                              setState(() {
                                _orders[idx] = item.copyWith(allowRandomDraw: val);
                              });
                            },
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.edit_rounded, size: 20),
                          onPressed: () => _showAddEditOrderDialog(item, idx),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline_rounded, size: 20, color: Colors.redAccent),
                          onPressed: () {
                            setState(() => _orders.removeAt(idx));
                          },
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    ),
    );
  }
}
