import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/order_engine.dart';

class InventoryView extends StatelessWidget {
  const InventoryView({super.key});

  void _showAddCustomEquipmentDialog(BuildContext context) {
    final engine = Provider.of<OrderEngine>(context, listen: false);
    final textController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Add Equipment / Gear Item'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Enter the name of the equipment or item you have available:'),
              const SizedBox(height: 14),
              Text(
                'Item Name',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8),
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: textController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'e.g. Vibrator, Cage, Blindfold, Desk Timer',
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
                final name = textController.text.trim();
                if (name.isNotEmpty) {
                  engine.addCustomEquipment(name);
                }
                Navigator.pop(ctx);
              },
              child: const Text('Add Item'),
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
    final allEquipment = engine.allRequiredEquipmentAcrossPacks;
    final ownedEquipment = engine.ownedEquipment;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Equipment & Gear Inventory'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded),
            tooltip: 'Add Equipment',
            onPressed: () => _showAddCustomEquipmentDialog(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [


          Row(
            children: [
              Text(
                'YOUR GEAR (${ownedEquipment.length} ACTIVE)',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  color: theme.colorScheme.primary,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _showAddCustomEquipmentDialog(context),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add Item'),
              ),
            ],
          ),
          const SizedBox(height: 8),

          if (allEquipment.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Column(
                    children: [
                      Icon(Icons.inventory_2_outlined, size: 48, color: theme.colorScheme.onSurface.withOpacity(0.3)),
                      const SizedBox(height: 12),
                      const Text(
                        'No equipment defined yet',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Packs with equipment requirements will automatically show items here, or you can add custom gear manually.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.5)),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            ...allEquipment.map((item) {
              final isOwned = engine.isEquipmentOwned(item);
              // Count matching tasks
              int matchingTasks = 0;
              for (final pack in engine.packs) {
                for (final order in pack.orders) {
                  if (order.requiredEquipment.any((e) => e.toLowerCase().trim() == item.toLowerCase().trim())) {
                    matchingTasks++;
                  }
                }
              }

              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: SwitchListTile(
                  title: Text(
                    item,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: isOwned ? theme.colorScheme.onSurface : theme.colorScheme.onSurface.withOpacity(0.5),
                    ),
                  ),
                  subtitle: Text(
                    matchingTasks > 0
                        ? 'Required by $matchingTasks directive${matchingTasks == 1 ? '' : 's'}'
                        : 'Custom equipment item',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                  value: isOwned,
                  onChanged: (val) {
                    engine.toggleEquipment(item, val);
                  },
                ),
              );
            }),
        ],
      ),
    );
  }
}
