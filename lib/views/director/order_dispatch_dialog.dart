import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/order_item.dart';
import '../../models/order_pack.dart';
import '../../models/partner_contact.dart';
import '../../services/order_engine.dart';
import '../../services/sync_service.dart';
import '../../services/partner_service.dart';

class OrderDispatchDialog extends StatefulWidget {
  final OrderItem? initialOrder;

  const OrderDispatchDialog({super.key, this.initialOrder});

  static Future<void> show(BuildContext context, {OrderItem? initialOrder}) {
    final isDesktop = MediaQuery.of(context).size.width > 700;
    if (isDesktop) {
      return showDialog(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => Dialog(
          backgroundColor: Theme.of(context).colorScheme.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          clipBehavior: Clip.antiAlias,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 700,
              maxHeight: 740,
              minWidth: 480,
            ),
            child: OrderDispatchDialog(initialOrder: initialOrder),
          ),
        ),
      );
    } else {
      return showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (ctx) => SizedBox(
          height: MediaQuery.of(context).size.height * 0.85,
          child: OrderDispatchDialog(initialOrder: initialOrder),
        ),
      );
    }
  }

  @override
  State<OrderDispatchDialog> createState() => _OrderDispatchDialogState();
}

class _OrderDispatchDialogState extends State<OrderDispatchDialog> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Search & Filter state for Library tab
  String _searchQuery = '';
  int? _selectedTierFilter;
  String? _selectedPackFilter;
  String? _selectedCategoryFilter;

  // Custom directive form state
  late TextEditingController _titleController;
  late TextEditingController _descController;
  late TextEditingController _equipmentController;
  int _selectedTier = 2;
  int _actionDurationSeconds = 120;
  int _actionValue = 2;
  String _actionUnit = 'Minutes';
  int _durationMinutes = 15;
  int _deadlineValue = 15;
  String _deadlineUnit = 'Minutes';
  DurationType _durationType = DurationType.actionTimer;
  VerificationType _verificationType = VerificationType.noteProof;
  int _rewardTokens = 20;
  int _penaltyTokens = 30;
  String _category = 'Director Directive';
  bool _allowRandomDraw = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialOrder != null ? 1 : 0,
    );

    _initFormWithOrder(widget.initialOrder);
  }

  void _initFormWithOrder(OrderItem? order) {
    if (order != null) {
      _titleController = TextEditingController(text: order.title);
      _descController = TextEditingController(text: order.description);
      _equipmentController = TextEditingController(text: order.requiredEquipment.join(', '));
      _selectedTier = order.tier;
      _actionDurationSeconds = order.actionDurationSeconds;
      _durationMinutes = order.durationMinutes;
      _durationType = order.durationType;
      _verificationType = order.verificationType;
      _rewardTokens = order.rewardTokens;
      _penaltyTokens = order.penaltyTokens;
      _category = order.category;
      _allowRandomDraw = order.allowRandomDraw;

      // Initialize split action timing
      if (order.actionDurationSeconds >= 3600 && order.actionDurationSeconds % 3600 == 0) {
        _actionValue = order.actionDurationSeconds ~/ 3600;
        _actionUnit = 'Hours';
      } else if (order.actionDurationSeconds >= 60 && order.actionDurationSeconds % 60 == 0) {
        _actionValue = order.actionDurationSeconds ~/ 60;
        _actionUnit = 'Minutes';
      } else {
        _actionValue = order.actionDurationSeconds > 0 ? order.actionDurationSeconds : 120;
        _actionUnit = 'Seconds';
      }

      // Initialize split deadline timing
      if (order.durationMinutes >= 60 && order.durationMinutes % 60 == 0) {
        _deadlineValue = order.durationMinutes ~/ 60;
        _deadlineUnit = 'Hours';
      } else {
        _deadlineValue = order.durationMinutes > 0 ? order.durationMinutes : 15;
        _deadlineUnit = 'Minutes';
      }
    } else {
      _titleController = TextEditingController();
      _descController = TextEditingController();
      _equipmentController = TextEditingController();
      _actionValue = 2;
      _actionUnit = 'Minutes';
      _deadlineValue = 15;
      _deadlineUnit = 'Minutes';
    }
  }

  void _populateForCustomization(OrderItem order) {
    setState(() {
      _titleController.text = order.title;
      _descController.text = order.description;
      _equipmentController.text = order.requiredEquipment.join(', ');
      _selectedTier = order.tier;
      _actionDurationSeconds = order.actionDurationSeconds;
      _durationMinutes = order.durationMinutes;
      _durationType = order.durationType;
      _verificationType = order.verificationType;
      _rewardTokens = order.rewardTokens;
      _penaltyTokens = order.penaltyTokens;
      _category = order.category;
      _allowRandomDraw = order.allowRandomDraw;

      if (order.actionDurationSeconds >= 3600 && order.actionDurationSeconds % 3600 == 0) {
        _actionValue = order.actionDurationSeconds ~/ 3600;
        _actionUnit = 'Hours';
      } else if (order.actionDurationSeconds >= 60 && order.actionDurationSeconds % 60 == 0) {
        _actionValue = order.actionDurationSeconds ~/ 60;
        _actionUnit = 'Minutes';
      } else {
        _actionValue = order.actionDurationSeconds > 0 ? order.actionDurationSeconds : 120;
        _actionUnit = 'Seconds';
      }

      if (order.durationMinutes >= 60 && order.durationMinutes % 60 == 0) {
        _deadlineValue = order.durationMinutes ~/ 60;
        _deadlineUnit = 'Hours';
      } else {
        _deadlineValue = order.durationMinutes > 0 ? order.durationMinutes : 15;
        _deadlineUnit = 'Minutes';
      }

      _tabController.animateTo(1);
    });
  }

  void _dispatchOrder(OrderItem order) {
    final sync = Provider.of<SyncService>(context, listen: false);
    final partnerSvc = Provider.of<PartnerService>(context, listen: false);

    final target = partnerSvc.activePartner ?? PartnerContact.self();

    sync.dispatchOrderToPlayer(order, targetPartner: target);

    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(target.isSelf
            ? 'Dispatched "${order.title}" to yourself!'
            : 'Dispatched "${order.title}" to ${target.displayName}!'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _titleController.dispose();
    _descController.dispose();
    _equipmentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engine = Provider.of<OrderEngine>(context);
    final partnerSvc = Provider.of<PartnerService>(context);
    final theme = Theme.of(context);
    final isDesktop = MediaQuery.of(context).size.width > 700;
    final activePartner = partnerSvc.activePartner ?? PartnerContact.self();

    return Container(
      height: isDesktop ? 740 : MediaQuery.of(context).size.height * 0.85,
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: isDesktop ? 20 : MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.purpleAccent.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.send_rounded, color: Colors.purpleAccent, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Director Task Dispatch Hub',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      activePartner.isSelf
                          ? 'Dispatching directive directly to yourself (This Device)'
                          : 'Dispatching directive to ${activePartner.displayName}',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Tabs
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceVariant.withOpacity(0.4),
              borderRadius: BorderRadius.circular(12),
            ),
            child: TabBar(
              controller: _tabController,
              indicatorSize: TabBarIndicatorSize.tab,
              indicator: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: theme.colorScheme.primary,
              ),
              labelColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
              unselectedLabelColor: theme.colorScheme.onSurface.withOpacity(0.7),
              labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              tabs: const [
                Tab(
                  icon: Icon(Icons.library_books_rounded, size: 18),
                  text: 'Browse Library Tasks',
                ),
                Tab(
                  icon: Icon(Icons.edit_note_rounded, size: 18),
                  text: 'Custom Directive',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Tab views
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildLibraryBrowserTab(engine, theme, isDesktop),
                _buildCustomDirectiveTab(engine, theme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLibraryBrowserTab(OrderEngine engine, ThemeData theme, bool isDesktop) {
    // Gather all orders across packs
    final allPacks = engine.packs;
    final List<MapEntry<OrderPack, OrderItem>> packOrders = [];
    final Set<String> categories = {};

    for (final pack in allPacks) {
      if (_selectedPackFilter != null && pack.id != _selectedPackFilter) continue;
      for (final order in pack.orders) {
        categories.add(order.category);
        if (_selectedCategoryFilter != null && order.category != _selectedCategoryFilter) continue;
        if (_selectedTierFilter != null && order.tier != _selectedTierFilter) continue;
        if (_searchQuery.isNotEmpty) {
          final q = _searchQuery.toLowerCase();
          final matchTitle = order.title.toLowerCase().contains(q);
          final matchDesc = order.description.toLowerCase().contains(q);
          final matchCat = order.category.toLowerCase().contains(q);
          final matchEq = order.requiredEquipment.any((e) => e.toLowerCase().contains(q));
          if (!matchTitle && !matchDesc && !matchCat && !matchEq) continue;
        }
        packOrders.add(MapEntry(pack, order));
      }
    }

    return Column(
      children: [
        // Search bar
        TextField(
          decoration: InputDecoration(
            hintText: 'Search tasks, gear, routines, keywords...',
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
            suffixIcon: _searchQuery.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear_rounded, size: 18),
                    onPressed: () => setState(() => _searchQuery = ''),
                  )
                : null,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            filled: true,
            fillColor: theme.colorScheme.surfaceVariant.withOpacity(0.2),
          ),
          onChanged: (val) => setState(() => _searchQuery = val.trim()),
        ),
        const SizedBox(height: 8),

        // Filter Bar (Pack dropdown + Tier chips)
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              // Pack selector
              DropdownButton<String?>(
                value: _selectedPackFilter,
                hint: const Text('All Packs', style: TextStyle(fontSize: 12)),
                underline: const SizedBox(),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('All Packs', style: TextStyle(fontSize: 12)),
                  ),
                  ...allPacks.map((p) => DropdownMenuItem<String?>(
                        value: p.id,
                        child: Text(p.title, style: const TextStyle(fontSize: 12)),
                      )),
                ],
                onChanged: (val) => setState(() => _selectedPackFilter = val),
              ),
              const SizedBox(width: 8),
              const Text('•', style: TextStyle(color: Colors.grey)),
              const SizedBox(width: 8),

              // Tier Filter Chips
              FilterChip(
                label: const Text('All Tiers', style: TextStyle(fontSize: 11)),
                selected: _selectedTierFilter == null,
                onSelected: (_) => setState(() => _selectedTierFilter = null),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 4),
              ...[1, 2, 3, 4, 5].map((t) => Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: FilterChip(
                      label: Text('T$t', style: const TextStyle(fontSize: 11)),
                      selected: _selectedTierFilter == t,
                      onSelected: (sel) => setState(() => _selectedTierFilter = sel ? t : null),
                      visualDensity: VisualDensity.compact,
                    ),
                  )),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // Orders List
        Expanded(
          child: packOrders.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.search_off_rounded, size: 48, color: theme.colorScheme.onSurface.withOpacity(0.3)),
                      const SizedBox(height: 8),
                      Text(
                        'No matching tasks found in library',
                        style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6)),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: packOrders.length,
                  itemBuilder: (context, index) {
                    final pack = packOrders[index].key;
                    final order = packOrders[index].value;
                    return _buildLibraryOrderCard(pack, order, theme);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildLibraryOrderCard(OrderPack pack, OrderItem order, ThemeData theme) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withOpacity(0.3),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: Category, Pack, Tier badge
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    order.category.toUpperCase(),
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'From: ${pack.title}',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurface.withOpacity(0.5),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.amber.withOpacity(0.3)),
                  ),
                  child: Text(
                    'Tier ${order.tier}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.amber,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Title
            Text(
              order.title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),

            // Description
            Text(
              order.description,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurface.withOpacity(0.75),
              ),
            ),
            const SizedBox(height: 10),

            // Details Row: Duration, Tokens, Gear
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _buildInfoChip(Icons.timer_outlined, order.formattedTiming),
                _buildInfoChip(Icons.add_circle_outline, '+${order.rewardTokens} Tok', color: Colors.greenAccent[400]),
                _buildInfoChip(Icons.remove_circle_outline, '-${order.penaltyTokens} Tok', color: Colors.redAccent),
                if (order.requiredEquipment.isNotEmpty)
                  _buildInfoChip(Icons.lock_outline, order.requiredEquipment.join(', '), color: Colors.blueAccent),
                if (order.verificationType != VerificationType.honorCheck)
                  _buildInfoChip(
                    order.verificationType == VerificationType.photoProof
                        ? Icons.photo_camera_rounded
                        : Icons.verified_user_outlined,
                    order.verificationType.displayName,
                    color: Colors.purpleAccent,
                  ),
                if (!order.allowRandomDraw)
                  _buildInfoChip(Icons.casino_outlined, 'Manual Only', color: Colors.amberAccent),
              ],
            ),
            const SizedBox(height: 12),

            // Action buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Customize', style: TextStyle(fontSize: 12)),
                  onPressed: () => _populateForCustomization(order),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  icon: const Icon(Icons.send_rounded, size: 16),
                  label: const Text('Dispatch Now', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  ),
                  onPressed: () => _dispatchOrder(order),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoChip(IconData icon, String text, {Color? color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: (color ?? Colors.grey).withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color ?? Colors.grey),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCustomDirectiveTab(OrderEngine engine, ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text(
            'Order Directive Title',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface.withOpacity(0.8),
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(
              hintText: 'e.g. 20-Minute Room Cleanse',
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Detailed Instructions & Requirements',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface.withOpacity(0.8),
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _descController,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'Specify exact parameters, posture, or steps...',
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Required Equipment (Optional, comma separated)',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface.withOpacity(0.8),
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _equipmentController,
            decoration: const InputDecoration(
              hintText: 'e.g. Vibrator, Cage, Blindfold',
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Timing Model',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface.withOpacity(0.8),
            ),
          ),
          const SizedBox(height: 6),
          DropdownButtonFormField<DurationType>(
            value: _durationType,
            decoration: const InputDecoration(),
            items: const [
              DropdownMenuItem(value: DurationType.instant, child: Text('Instant / Untimed')),
              DropdownMenuItem(value: DurationType.actionTimer, child: Text('Action Routine Timer (Alarms on end)')),
              DropdownMenuItem(value: DurationType.deadlineCountdown, child: Text('Completion Deadline Countdown')),
              DropdownMenuItem(value: DurationType.actionWithDeadline, child: Text('Action Timer + Completion Deadline')),
              DropdownMenuItem(value: DurationType.dailyWindow, child: Text('End of Day Window')),
            ],
            onChanged: (val) {
              if (val != null) setState(() => _durationType = val);
            },
          ),
          if (_durationType == DurationType.actionTimer || _durationType == DurationType.actionWithDeadline) ...[
            const SizedBox(height: 14),
            Text(
              'Action Routine Duration',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface.withOpacity(0.8),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    key: ValueKey('action_val_$_actionValue'),
                    initialValue: '$_actionValue',
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(hintText: 'e.g. 2'),
                    onChanged: (val) => _actionValue = int.tryParse(val) ?? 1,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<String>(
                    value: _actionUnit,
                    decoration: const InputDecoration(),
                    items: const [
                      DropdownMenuItem(value: 'Seconds', child: Text('Seconds')),
                      DropdownMenuItem(value: 'Minutes', child: Text('Minutes')),
                      DropdownMenuItem(value: 'Hours', child: Text('Hours')),
                    ],
                    onChanged: (val) {
                      if (val != null) setState(() => _actionUnit = val);
                    },
                  ),
                ),
              ],
            ),
          ],
          if (_durationType == DurationType.deadlineCountdown || _durationType == DurationType.actionWithDeadline) ...[
            const SizedBox(height: 14),
            Text(
              'Completion Deadline Window',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface.withOpacity(0.8),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    key: ValueKey('deadline_val_$_deadlineValue'),
                    initialValue: '$_deadlineValue',
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(hintText: 'e.g. 30'),
                    onChanged: (val) => _deadlineValue = int.tryParse(val) ?? 1,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<String>(
                    value: _deadlineUnit,
                    decoration: const InputDecoration(),
                    items: const [
                      DropdownMenuItem(value: 'Seconds', child: Text('Seconds')),
                      DropdownMenuItem(value: 'Minutes', child: Text('Minutes')),
                      DropdownMenuItem(value: 'Hours', child: Text('Hours')),
                    ],
                    onChanged: (val) {
                      if (val != null) setState(() => _deadlineUnit = val);
                    },
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          Text(
            'Verification Required',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface.withOpacity(0.8),
            ),
          ),
          const SizedBox(height: 6),
          DropdownButtonFormField<VerificationType>(
            value: _verificationType,
            decoration: const InputDecoration(),
            items: VerificationType.values
                .map((v) => DropdownMenuItem(value: v, child: Text(v.displayName)))
                .toList(),
            onChanged: (val) {
              if (val != null) setState(() => _verificationType = val);
            },
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Reward Tokens (+)',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface.withOpacity(0.8),
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextFormField(
                      key: ValueKey('reward_$_rewardTokens'),
                      initialValue: '$_rewardTokens',
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(hintText: '20'),
                      onChanged: (val) => _rewardTokens = int.tryParse(val) ?? 20,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Penalty Tokens (-)',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface.withOpacity(0.8),
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextFormField(
                      key: ValueKey('penalty_$_penaltyTokens'),
                      initialValue: '$_penaltyTokens',
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(hintText: '30'),
                      onChanged: (val) => _penaltyTokens = int.tryParse(val) ?? 30,
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
                _allowRandomDraw ? Icons.casino_rounded : Icons.casino_outlined,
                color: _allowRandomDraw ? theme.colorScheme.primary : Colors.grey,
              ),
              title: const Text('Include in Random Draws', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              subtitle: Text(
                _allowRandomDraw
                    ? 'Enabled: Can be randomly drawn from the deck.'
                    : 'Disabled: Manual assignment only (excluded from random draws).',
                style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.6)),
              ),
              value: _allowRandomDraw,
              onChanged: (val) => setState(() => _allowRandomDraw = val),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.send_and_archive_rounded),
              label: const Text('DISPATCH ORDER'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
              ),
              onPressed: () {
                if (_titleController.text.trim().isEmpty) return;
                final eqList = _equipmentController.text
                    .split(',')
                    .map((e) => e.trim())
                    .where((e) => e.isNotEmpty)
                    .toList();

                int computedActionSecs = _actionValue;
                if (_actionUnit == 'Hours') computedActionSecs = _actionValue * 3600;
                if (_actionUnit == 'Minutes') computedActionSecs = _actionValue * 60;

                int computedDeadlineMins = _deadlineValue;
                if (_deadlineUnit == 'Hours') computedDeadlineMins = _deadlineValue * 60;
                if (_deadlineUnit == 'Seconds') computedDeadlineMins = (_deadlineValue / 60).ceil().clamp(1, 999999);

                final newOrder = OrderItem(
                  title: _titleController.text.trim(),
                  description: _descController.text.trim(),
                  tier: _selectedTier,
                  durationType: _durationType,
                  actionDurationSeconds: computedActionSecs,
                  durationMinutes: computedDeadlineMins,
                  verificationType: _verificationType,
                  rewardTokens: _rewardTokens,
                  penaltyTokens: _penaltyTokens,
                  allowRandomDraw: _allowRandomDraw,
                  requiredEquipment: eqList,
                  category: _category,
                );

                _dispatchOrder(newOrder);
              },
            ),
          ),
        ],
      ),
    );
  }
}
