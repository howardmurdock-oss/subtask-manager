import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/reward_pack.dart';
import '../../models/reward_item.dart';
import '../../services/order_engine.dart';
import '../../widgets/draggable_dialog.dart';

class RewardStudioView extends StatefulWidget {
  final RewardPack? existingPack;

  const RewardStudioView({super.key, this.existingPack});

  @override
  State<RewardStudioView> createState() => _RewardStudioViewState();
}

class _RewardStudioViewState extends State<RewardStudioView> {
  late TextEditingController _titleController;
  late TextEditingController _descController;
  late TextEditingController _authorController;
  late List<RewardItem> _rewards;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.existingPack?.title ?? '');
    _descController = TextEditingController(text: widget.existingPack?.description ?? '');
    _authorController = TextEditingController(text: widget.existingPack?.author ?? 'Director');
    _rewards = widget.existingPack != null
        ? List<RewardItem>.from(widget.existingPack!.rewards)
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

  void _showAddEditRewardDialog([RewardItem? existingReward, int? index]) {
    final titleCtrl = TextEditingController(text: existingReward?.title ?? '');
    final descCtrl = TextEditingController(text: existingReward?.description ?? '');
    final costCtrl = TextEditingController(text: existingReward != null ? '${existingReward.cost}' : '50');
    final catCtrl = TextEditingController(text: existingReward?.category ?? 'Privilege');
    bool requiresApproval = existingReward?.requiresDirectorApproval ?? false;
    bool isEnabled = existingReward?.isEnabled ?? true;

    DraggableDialog.show(
      context: context,
      title: existingReward != null ? 'Edit Privilege / Reward' : 'New Privilege / Reward',
      maxWidth: 600,
      hasUnsavedChanges: () {
        if (existingReward == null) {
          return titleCtrl.text.trim().isNotEmpty ||
              descCtrl.text.trim().isNotEmpty ||
              (catCtrl.text.trim().isNotEmpty && catCtrl.text.trim() != 'Privilege') ||
              costCtrl.text.trim() != '50';
        }
        if (titleCtrl.text.trim() != existingReward.title.trim()) return true;
        if (descCtrl.text.trim() != existingReward.description.trim()) return true;
        if (catCtrl.text.trim() != existingReward.category.trim()) return true;
        if ((int.tryParse(costCtrl.text.trim()) ?? 50) != existingReward.cost) return true;
        if (requiresApproval != existingReward.requiresDirectorApproval) return true;
        if (isEnabled != existingReward.isEnabled) return true;
        return false;
      },
      builder: (ctx, setModalState) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildFieldLabel('Reward Title', context),
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(hintText: 'e.g. 15-Minute Rest Break'),
            ),
            const SizedBox(height: 14),
            _buildFieldLabel('Description', context),
            TextField(
              controller: descCtrl,
              maxLines: 2,
              decoration: const InputDecoration(hintText: 'What privilege or perk does this grant?'),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildFieldLabel('Token Cost', context),
                      TextField(
                        controller: costCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(hintText: '50'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildFieldLabel('Category', context),
                      TextField(
                        controller: catCtrl,
                        decoration: const InputDecoration(hintText: 'e.g. Break, Privilege'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Card(
              child: SwitchListTile(
                secondary: Icon(
                  requiresApproval ? Icons.verified_user_rounded : Icons.lock_open_rounded,
                  color: requiresApproval ? Colors.amber : Colors.grey,
                ),
                title: const Text('Requires Director Approval', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                subtitle: Text(
                  requiresApproval
                      ? 'Player must request permission before redeeming.'
                      : 'Instant unlock: tokens deducted immediately upon claim.',
                  style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
                ),
                value: requiresApproval,
                onChanged: (val) => setModalState(() => requiresApproval = val),
              ),
            ),
            const SizedBox(height: 8),
            Card(
              child: SwitchListTile(
                secondary: Icon(
                  isEnabled ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                  color: isEnabled ? Theme.of(context).colorScheme.primary : Colors.grey,
                ),
                title: const Text('Enabled in Shop', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                subtitle: Text(
                  isEnabled ? 'Visible and purchasable in the shop.' : 'Hidden from shop.',
                  style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
                ),
                value: isEnabled,
                onChanged: (val) => setModalState(() => isEnabled = val),
              ),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  if (titleCtrl.text.trim().isEmpty) return;
                  final reward = RewardItem(
                    id: existingReward?.id,
                    title: titleCtrl.text.trim(),
                    description: descCtrl.text.trim(),
                    cost: int.tryParse(costCtrl.text.trim()) ?? 50,
                    category: catCtrl.text.trim().isEmpty ? 'Privilege' : catCtrl.text.trim(),
                    requiresDirectorApproval: requiresApproval,
                    isEnabled: isEnabled,
                  );

                  setState(() {
                    if (index != null) {
                      _rewards[index] = reward;
                    } else {
                      _rewards.add(reward);
                    }
                  });
                  Navigator.pop(ctx);
                },
                child: Text(existingReward != null ? 'Update Reward' : 'Add Reward'),
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
          _rewards.isNotEmpty;
    }
    final p = widget.existingPack!;
    if (_titleController.text.trim() != p.title.trim()) return true;
    if (_descController.text.trim() != p.description.trim()) return true;
    if (_authorController.text.trim() != p.author.trim()) return true;
    if (_rewards.length != p.rewards.length) return true;
    for (int i = 0; i < _rewards.length; i++) {
      if (_rewards[i].id != p.rewards[i].id ||
          _rewards[i].title != p.rewards[i].title ||
          _rewards[i].description != p.rewards[i].description ||
          _rewards[i].cost != p.rewards[i].cost ||
          _rewards[i].category != p.rewards[i].category ||
          _rewards[i].requiresDirectorApproval != p.rewards[i].requiresDirectorApproval ||
          _rewards[i].isEnabled != p.rewards[i].isEnabled) {
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
            'You have unsaved changes in this reward pack. Would you like to save your changes before exiting?',
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
        const SnackBar(content: Text('Please enter a Reward Pack title.')),
      );
      return false;
    }

    final engine = Provider.of<OrderEngine>(context, listen: false);
    final pack = RewardPack(
      id: widget.existingPack?.id,
      title: _titleController.text.trim(),
      description: _descController.text.trim(),
      author: _authorController.text.trim().isEmpty ? 'Director' : _authorController.text.trim(),
      isEnabled: widget.existingPack?.isEnabled ?? true,
      rewards: _rewards,
    );

    if (widget.existingPack != null) {
      engine.updateRewardPack(pack);
    } else {
      engine.addRewardPack(pack);
    }

    if (popAfterSave && context.mounted) {
      Navigator.pop(context);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Reward Pack "${pack.title}" saved successfully!'),
        behavior: SnackBarBehavior.floating,
      ),
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
          title: Text(widget.existingPack != null ? 'Edit Reward Pack' : 'Create Custom Reward Pack'),
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
            _buildFieldLabel('Reward Pack Title', context),
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(
              hintText: 'e.g. Sensory & Pampering Passes',
            ),
          ),
          const SizedBox(height: 16),
          _buildFieldLabel('Description', context),
          TextField(
            controller: _descController,
            maxLines: 2,
            decoration: const InputDecoration(
              hintText: 'e.g. Special massages, clothing choice, and relaxation privileges.',
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
                'PRIVILEGES & REWARDS (${_rewards.length})',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 1.0),
              ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: () => _showAddEditRewardDialog(),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add Reward'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_rewards.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    'No rewards in this pack yet. Tap "Add Reward" above.',
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
              itemCount: _rewards.length,
              onReorder: (oldIndex, newIndex) {
                setState(() {
                  if (oldIndex < newIndex) {
                    newIndex -= 1;
                  }
                  final item = _rewards.removeAt(oldIndex);
                  _rewards.insert(newIndex, item);
                });
              },
              itemBuilder: (context, idx) {
                final item = _rewards[idx];
                return Card(
                  key: ValueKey(item.id),
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ReorderableDragStartListener(
                          index: idx,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                            child: const Icon(Icons.drag_indicator_rounded, color: Colors.grey),
                          ),
                        ),
                        const SizedBox(width: 4),
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: Theme.of(context).colorScheme.primary.withOpacity(0.15),
                          child: Text('${item.cost}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                        ),
                      ],
                    ),
                    title: Text(item.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('${item.category} • ${item.cost} Tokens ${item.requiresDirectorApproval ? "• Needs Approval" : "• Instant"}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_rounded, size: 20),
                          onPressed: () => _showAddEditRewardDialog(item, idx),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline_rounded, size: 20, color: Colors.redAccent),
                          onPressed: () {
                            setState(() => _rewards.removeAt(idx));
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
