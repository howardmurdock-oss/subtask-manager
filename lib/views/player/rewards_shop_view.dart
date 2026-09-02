import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../services/order_engine.dart';
import '../../models/reward_item.dart';
import '../../models/active_redemption.dart';

class RewardsShopView extends StatefulWidget {
  const RewardsShopView({super.key});

  @override
  State<RewardsShopView> createState() => _RewardsShopViewState();
}

class _RewardsShopViewState extends State<RewardsShopView> {
  String _selectedCategory = 'All';

  void _showRedeemConfirmation(BuildContext context, RewardItem reward) {
    final engine = Provider.of<OrderEngine>(context, listen: false);
    final noteController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('Redeem "${reward.title}"?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Cost: ${reward.cost} Tokens', style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(reward.description, style: const TextStyle(fontSize: 13)),
              if (reward.requiresDirectorApproval) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.info_outline_rounded, size: 16, color: Colors.amber),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Requires Director review & approval.',
                          style: TextStyle(fontSize: 11, color: Colors.amber),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Personal Note / Specification (Optional)',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: noteController,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    hintText: 'e.g. For movie night this Friday...',
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final ok = engine.redeemReward(reward, note: noteController.text.trim());
                Navigator.pop(ctx);
                if (ok) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        reward.requiresDirectorApproval
                            ? 'Privilege requested! Awaiting Director approval.'
                            : 'Privilege claimed successfully!',
                      ),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Insufficient tokens to redeem this reward.'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
              child: Text('Confirm (${reward.cost} Tokens)'),
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
    final allRewards = engine.rewards.where((r) => r.isEnabled).toList();
    final redemptions = engine.redemptions;
    final dateFormat = DateFormat('MMM d, h:mm a');

    // Extract unique categories
    final categories = ['All', ...allRewards.map((r) => r.category).toSet().toList()];

    // Filter by selected category
    final filteredRewards = _selectedCategory == 'All'
        ? allRewards
        : allRewards.where((r) => r.category.toLowerCase() == _selectedCategory.toLowerCase()).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Privilege & Reward Shop'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Wallet Balance Hero Card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: Colors.amber.withOpacity(0.2),
                    radius: 26,
                    child: const Icon(Icons.toll_rounded, size: 28, color: Colors.amber),
                  ),
                  const SizedBox(width: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'AVAILABLE BALANCE',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${engine.stats.tokens} Tokens',
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Categories Filter Chips
          if (categories.length > 2) ...[
            SizedBox(
              height: 38,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: categories.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (ctx, idx) {
                  final cat = categories[idx];
                  final isSelected = _selectedCategory.toLowerCase() == cat.toLowerCase();
                  return ChoiceChip(
                    label: Text(cat),
                    selected: isSelected,
                    onSelected: (selected) {
                      if (selected) {
                        setState(() => _selectedCategory = cat);
                      }
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
          ],

          Text(
            'AVAILABLE PRIVILEGES & PERKS (${filteredRewards.length})',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: theme.colorScheme.onSurface.withOpacity(0.6),
            ),
          ),
          const SizedBox(height: 8),

          if (filteredRewards.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    allRewards.isEmpty
                        ? 'No active reward packs enabled by Director.'
                        : 'No rewards in the "$_selectedCategory" category.',
                    style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.5)),
                  ),
                ),
              ),
            )
          else
            ...filteredRewards.map((reward) {
              final canAfford = engine.canAfford(reward);

              return Card(
                margin: const EdgeInsets.symmetric(vertical: 6),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  reward.title,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  reward.category.toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: theme.colorScheme.primary,
                                    letterSpacing: 0.8,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: canAfford
                                  ? Colors.greenAccent.withOpacity(0.15)
                                  : Colors.redAccent.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: canAfford
                                    ? Colors.greenAccent.withOpacity(0.4)
                                    : Colors.redAccent.withOpacity(0.3),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.toll_rounded,
                                  size: 14,
                                  color: canAfford ? Colors.greenAccent[400] : Colors.redAccent,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '${reward.cost}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                    color: canAfford ? Colors.greenAccent[400] : Colors.redAccent,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        reward.description,
                        style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withOpacity(0.8)),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (reward.requiresDirectorApproval) ...[
                            Icon(Icons.lock_person_rounded, size: 14, color: theme.colorScheme.onSurface.withOpacity(0.5)),
                            const SizedBox(width: 4),
                            Text(
                              'Approval Required',
                              style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.5)),
                            ),
                            const Spacer(),
                          ],
                          ElevatedButton.icon(
                            onPressed: canAfford ? () => _showRedeemConfirmation(context, reward) : null,
                            icon: const Icon(Icons.shopping_bag_outlined, size: 16),
                            label: const Text('Redeem Privilege'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }),

          // Redemptions History Section
          if (redemptions.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              'REDEMPTIONS & CLAIMS HISTORY',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 8),
            ...redemptions.map((redemption) {
              Color statusColor;
              String statusLabel;

              switch (redemption.status) {
                case RedemptionStatus.pending:
                  statusColor = Colors.amber;
                  statusLabel = 'Pending Review';
                  break;
                case RedemptionStatus.approved:
                  statusColor = Colors.greenAccent[400]!;
                  statusLabel = 'Approved';
                  break;
                case RedemptionStatus.claimed:
                  statusColor = Colors.cyanAccent;
                  statusLabel = 'Claimed';
                  break;
                case RedemptionStatus.rejected:
                  statusColor = Colors.redAccent;
                  statusLabel = 'Declined (Refunded)';
                  break;
              }

              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  title: Text(redemption.reward.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${redemption.reward.cost} Tokens • ${dateFormat.format(redemption.requestedAt)}',
                        style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.6)),
                      ),
                      if (redemption.note?.isNotEmpty == true)
                        Text('Note: "${redemption.note}"', style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic)),
                      if (redemption.directorNote?.isNotEmpty == true)
                        Text('Director: "${redemption.directorNote}"', style: TextStyle(fontSize: 11, color: statusColor)),
                    ],
                  ),
                  trailing: Chip(
                    label: Text(statusLabel, style: TextStyle(fontSize: 11, color: statusColor)),
                    backgroundColor: statusColor.withOpacity(0.12),
                    side: BorderSide(color: statusColor.withOpacity(0.4)),
                  ),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }
}
