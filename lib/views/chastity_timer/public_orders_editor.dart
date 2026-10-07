import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/chastity_timer.dart';
import '../../models/order_item.dart';
import '../../services/order_engine.dart';

/// What the public may order from a timer's page: the list - picked from
/// the app's orders or written here - and the rules around it.
class PublicOrdersEditor extends StatelessWidget {
  const PublicOrdersEditor({
    super.key,
    required this.value,
    required this.onChanged,
    required this.isDirector,
    required this.hasDirector,
  });

  final PublicOrdersSettings value;
  final ValueChanged<PublicOrdersSettings> onChanged;

  /// Whether the director is setting this up (for the player).
  final bool isDirector;

  /// Whether the timer has a director to send proof to.
  final bool hasDirector;

  static String describe(PublicOrderDef o) {
    final bits = <String>[
      if ((o.durationType == DurationType.deadlineCountdown || o.durationType == DurationType.actionWithDeadline) &&
          o.deadlineMinutes > 0)
        '${o.deadlineMinutes} min',
      if (o.verification == VerificationType.photoProof) 'photo proof',
      if (o.verification == VerificationType.noteProof) 'written proof',
      if (o.rewardTokens > 0) '+${o.rewardTokens}',
      if (o.penaltyTokens > 0) '−${o.penaltyTokens} if failed',
    ];
    return bits.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = value;
    final directorLabel = isDirector ? 'You' : (hasDirector ? 'Your director' : 'Nobody - it stays in your log');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: v.enabled,
          onChanged: (on) => onChanged(v.copyWith(enabled: on)),
          title: const Text('Let visitors send orders'),
          subtitle: const Text("From a list you choose - they can't write their own."),
        ),
        if (v.enabled) ...[
          if (v.orders.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text('No orders yet. Add at least one.',
                  style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.65))),
            ),
          for (final o in v.orders)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(o.title, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: describe(o).isEmpty ? null : Text(describe(o)),
              trailing: IconButton(
                icon: const Icon(Icons.close_rounded),
                tooltip: 'Remove',
                onPressed: () => onChanged(v.copyWith(orders: v.orders.where((x) => x.id != o.id).toList())),
              ),
            ),
          Wrap(spacing: 8, children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.playlist_add_rounded, size: 18),
              label: const Text('Add from my orders'),
              onPressed: () async {
                final picked = await _pickFromLibrary(context, v.orders);
                if (picked != null) onChanged(v.copyWith(orders: [...v.orders, ...picked]));
              },
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.edit_note_rounded, size: 18),
              label: const Text('Write one'),
              onPressed: () async {
                final written = await _writeOne(context);
                if (written != null) onChanged(v.copyWith(orders: [...v.orders, written]));
              },
            ),
          ]),
          const SizedBox(height: 8),
          _Counter(
            label: 'Orders each visitor may send a day',
            value: v.perVisitorDaily,
            min: 1,
            max: 20,
            onChanged: (n) => onChanged(v.copyWith(perVisitorDaily: n)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: v.maxQueued != null,
            onChanged: (on) => onChanged(on ? v.copyWith(maxQueued: 5) : v.copyWith(noLimit: true)),
            title: const Text('Limit how many can wait'),
            subtitle: const Text('Otherwise they all wait their turn, one at a time.'),
          ),
          if (v.maxQueued != null)
            _Counter(
              label: 'Waiting or in progress at once',
              value: v.maxQueued!,
              min: 1,
              max: 100,
              onChanged: (n) => onChanged(v.copyWith(maxQueued: n)),
            ),
          _Counter(
            label: 'Skips a day',
            value: v.skipsPerDay,
            min: 0,
            max: 20,
            onChanged: (n) => onChanged(v.copyWith(skipsPerDay: n)),
          ),
          _Counter(
            label: 'Pause after a skip',
            value: v.skipPauseMinutes,
            min: 5,
            max: 240,
            step: 5,
            unit: 'min',
            onChanged: (n) => onChanged(v.copyWith(skipPauseMinutes: n)),
          ),
          const SizedBox(height: 8),
          Text('Photo proof goes to', style: theme.textTheme.labelLarge),
          RadioListTile<PublicProofTo>(
            contentPadding: EdgeInsets.zero,
            value: PublicProofTo.director,
            groupValue: v.proofTo,
            onChanged: (p) => onChanged(v.copyWith(proofTo: p)),
            title: Text(directorLabel),
          ),
          RadioListTile<PublicProofTo>(
            contentPadding: EdgeInsets.zero,
            value: PublicProofTo.issuer,
            groupValue: v.proofTo,
            onChanged: (p) => onChanged(v.copyWith(proofTo: p)),
            title: const Text('Whoever sent the order'),
          ),
          if (v.proofTo == PublicProofTo.issuer)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${isDirector ? "Your player's" : 'Your'} photos go to strangers: anyone with the link who sends an '
                "order. They're encrypted so only that person's browser can open them, kept for a day, and the "
                'page asks visitors to confirm they are adults. Only choose this if '
                '${isDirector ? 'your player is' : "you're"} comfortable with that.',
                style: const TextStyle(fontSize: 12),
              ),
            ),
        ],
      ],
    );
  }

  static Future<List<PublicOrderDef>?> _pickFromLibrary(BuildContext context, List<PublicOrderDef> already) {
    final engine = Provider.of<OrderEngine>(context, listen: false);
    final taken = already.map((o) => o.id).toSet();
    final all = <OrderItem>[
      for (final pack in engine.packs.where((p) => p.isEnabled)) ...pack.orders,
    ];
    final chosen = <String>{};
    return showDialog<List<PublicOrderDef>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Add from my orders'),
          content: SizedBox(
            width: 440,
            height: 420,
            child: all.isEmpty
                ? const Center(child: Text('No orders in your enabled packs.'))
                : ListView(
                    children: [
                      for (final o in all)
                        CheckboxListTile(
                          dense: true,
                          value: taken.contains(PublicOrderDef.fromOrder(o).id) || chosen.contains(o.id),
                          onChanged: taken.contains(PublicOrderDef.fromOrder(o).id)
                              ? null
                              : (on) => setState(() => on == true ? chosen.add(o.id) : chosen.remove(o.id)),
                          title: Text(o.title),
                          subtitle: Text(describe(PublicOrderDef.fromOrder(o))),
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(
                ctx,
                all.where((o) => chosen.contains(o.id)).map(PublicOrderDef.fromOrder).toList(),
              ),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  static Future<PublicOrderDef?> _writeOne(BuildContext context) {
    final title = TextEditingController();
    final description = TextEditingController();
    final minutes = TextEditingController();
    final reward = TextEditingController(text: '5');
    final penalty = TextEditingController(text: '0');
    var proof = VerificationType.honorCheck;
    final digits = [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(5)];
    return showDialog<PublicOrderDef>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Write an order'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: title, maxLength: 80, decoration: const InputDecoration(labelText: 'Title')),
                TextField(
                  controller: description,
                  maxLength: 600,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'What to do (optional)'),
                ),
                TextField(
                  controller: minutes,
                  keyboardType: TextInputType.number,
                  inputFormatters: digits,
                  decoration: const InputDecoration(labelText: 'Minutes to do it', helperText: 'Empty for no time limit'),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<VerificationType>(
                  value: proof,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Proof'),
                  items: const [
                    DropdownMenuItem(value: VerificationType.honorCheck, child: Text('None - their word')),
                    DropdownMenuItem(value: VerificationType.noteProof, child: Text('A written note')),
                    DropdownMenuItem(value: VerificationType.photoProof, child: Text('A photo')),
                  ],
                  onChanged: (p) => setState(() => proof = p ?? VerificationType.honorCheck),
                ),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: reward,
                      keyboardType: TextInputType.number,
                      inputFormatters: digits,
                      decoration: const InputDecoration(labelText: 'Tokens if done'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: penalty,
                      keyboardType: TextInputType.number,
                      inputFormatters: digits,
                      decoration: const InputDecoration(labelText: 'Tokens lost if not'),
                    ),
                  ),
                ]),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (title.text.trim().isEmpty) return;
                final mins = int.tryParse(minutes.text) ?? 0;
                Navigator.pop(
                  ctx,
                  PublicOrderDef(
                    id: 'w${DateTime.now().microsecondsSinceEpoch}',
                    title: title.text.trim(),
                    description: description.text.trim(),
                    category: 'Public',
                    durationType: mins > 0 ? DurationType.deadlineCountdown : DurationType.instant,
                    deadlineMinutes: mins,
                    verification: proof,
                    rewardTokens: int.tryParse(reward.text) ?? 0,
                    penaltyTokens: int.tryParse(penalty.text) ?? 0,
                  ),
                );
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small number with - and + either side.
class _Counter extends StatelessWidget {
  const _Counter({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.step = 1,
    this.unit,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final int step;
  final String? unit;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(child: Text(label)),
      IconButton(
        icon: const Icon(Icons.remove_circle_outline_rounded),
        onPressed: value - step < min ? null : () => onChanged(value - step),
      ),
      SizedBox(
        width: 56,
        child: Text(unit == null ? '$value' : '$value $unit', textAlign: TextAlign.center),
      ),
      IconButton(
        icon: const Icon(Icons.add_circle_outline_rounded),
        onPressed: value + step > max ? null : () => onChanged(value + step),
      ),
    ]);
  }
}
