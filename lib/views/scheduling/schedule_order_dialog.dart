import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/scheduled_order_rule.dart';
import '../../models/order_item.dart';
import '../../models/partner_contact.dart';
import '../../services/schedule_service.dart';
import '../../services/order_engine.dart';
import '../../services/partner_service.dart';
import '../../widgets/draggable_dialog.dart';

class ScheduleOrderDialog {
  static void show(
    BuildContext context, {
    required bool isDirectorMode,
  }) {
    final scheduleSvc = Provider.of<ScheduleService>(context, listen: false);

    if (!scheduleSvc.isUnlocked) {
      _showPatreonGate(context, isDirectorMode: isDirectorMode);
      return;
    }

    _showScheduleModal(context, isDirectorMode: isDirectorMode);
  }

  static void _showPatreonGate(
    BuildContext context, {
    required bool isDirectorMode,
  }) {
    final codeCtrl = TextEditingController();
    String? errorMsg;
    bool isLoading = false;

    DraggableDialog.show(
      context: context,
      title: 'Patreon Exclusive: Scheduled Orders',
      maxWidth: 480,
      builder: (dialogCtx, setDialogState) {
        final theme = Theme.of(dialogCtx);

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.purple.withOpacity(0.12),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.purpleAccent.withOpacity(0.4), width: 2),
              ),
              child: const Icon(
                Icons.schedule_rounded,
                size: 48,
                color: Colors.purpleAccent,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.amber.withOpacity(0.15),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.amber.withOpacity(0.4)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.stars_rounded, size: 16, color: Colors.amber),
                  SizedBox(width: 6),
                  Text(
                    'CREATOR COMMUNITY EXCLUSIVE',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.1,
                      color: Colors.amber,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Automated Directive Scheduling',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'Schedule automated dispatches at exact or random times with hourly, daily, or weekly recurrence.',
              style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.7), height: 1.4),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            TextField(
              controller: codeCtrl,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: 'Enter Community Passcode',
                hintText: 'e.g. PATREON-VIP',
                prefixIcon: const Icon(Icons.key_rounded),
                border: const OutlineInputBorder(),
                errorText: errorMsg,
              ),
              onSubmitted: (_) {
                _verifyAndUnlock(dialogCtx, context, codeCtrl, setDialogState, isDirectorMode, (loading) {
                  setDialogState(() => isLoading = loading);
                }, (err) {
                  setDialogState(() => errorMsg = err);
                });
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
                ElevatedButton.icon(
                  icon: isLoading
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.lock_open_rounded, size: 18),
                  label: const Text('Unlock Scheduling'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.purpleAccent,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: isLoading
                      ? null
                      : () {
                          _verifyAndUnlock(dialogCtx, context, codeCtrl, setDialogState, isDirectorMode, (loading) {
                            setDialogState(() => isLoading = loading);
                          }, (err) {
                            setDialogState(() => errorMsg = err);
                          });
                        },
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  static void _verifyAndUnlock(
    BuildContext dialogCtx,
    BuildContext rootCtx,
    TextEditingController codeCtrl,
    StateSetter setDialogState,
    bool isDirectorMode,
    Function(bool) setLoading,
    Function(String?) setError,
  ) {
    final code = codeCtrl.text.trim();
    if (code.isEmpty) {
      setError('Please enter an access code');
      return;
    }

    setLoading(true);
    setError(null);

    final scheduleSvc = Provider.of<ScheduleService>(rootCtx, listen: false);
    final success = scheduleSvc.unlockWithPasscode(code);

    setLoading(false);

    if (success) {
      Navigator.pop(dialogCtx);
      ScaffoldMessenger.of(rootCtx).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.stars_rounded, color: Colors.amber),
              SizedBox(width: 10),
              Text('Scheduled Directives & Protocols Unlocked!'),
            ],
          ),
          backgroundColor: Theme.of(rootCtx).colorScheme.primaryContainer,
          behavior: SnackBarBehavior.floating,
        ),
      );
      _showScheduleModal(rootCtx, isDirectorMode: isDirectorMode);
    } else {
      setError('Invalid access code. Check Patreon posts for the current code.');
    }
  }

  static void _showScheduleModal(
    BuildContext context, {
    required bool isDirectorMode,
  }) {
    final engine = Provider.of<OrderEngine>(context, listen: false);
    final partnerSvc = Provider.of<PartnerService>(context, listen: false);
    final allPacks = engine.packs.where((p) => p.isEnabled).toList();

    final categories = allPacks
        .expand((p) => p.orders)
        .map((o) => o.category)
        .toSet()
        .toList();

    int activeTabIndex = 0; // 0 = New Schedule, 1 = Active Protocols

    // Director State
    bool isSpecificOrder = false;
    OrderItem? selectedSpecificOrder;
    String? selectedPackId = allPacks.isNotEmpty ? allPacks.first.id : null;
    final pairedScheduleContacts = partnerSvc.unblockedContacts;
    final allScheduleRecipients = [
      PartnerContact.self(),
      ...pairedScheduleContacts,
    ];
    PartnerContact? selectedPartner = partnerSvc.activePartner ?? PartnerContact.self();

    // Common Filter State
    String? selectedCategory;
    int minTier = 1;
    int maxTier = 5;

    // Timing State
    ScheduleTimingMode timingMode = ScheduleTimingMode.specificTime;
    DateTime scheduledDate = DateTime.now();
    TimeOfDay scheduledTime = TimeOfDay.fromDateTime(
      DateTime.now().add(const Duration(hours: 1)),
    );
    RepeatFrequency frequency = RepeatFrequency.daily;

    // Window Timing (Player Mode)
    TimeOfDay windowStartTime = const TimeOfDay(hour: 15, minute: 0);
    TimeOfDay windowEndTime = const TimeOfDay(hour: 21, minute: 0);

    final titleCtrl = TextEditingController();

    DraggableDialog.show(
      context: context,
      title: isDirectorMode ? 'Director: Schedule Directives' : 'Player: Schedule Orders',
      maxWidth: 580,
      builder: (dialogCtx, setDialogState) {
        final theme = Theme.of(dialogCtx);
        final scheduleSvc = Provider.of<ScheduleService>(dialogCtx);
        final currentRules = isDirectorMode ? scheduleSvc.directorRules : scheduleSvc.playerRules;

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Tab Switcher
            Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceVariant.withOpacity(0.4),
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.all(4),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => setDialogState(() => activeTabIndex = 0),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: activeTabIndex == 0 ? theme.colorScheme.primary : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Create Schedule',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: activeTabIndex == 0
                                ? (theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white)
                                : theme.colorScheme.onSurface.withOpacity(0.7),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => setDialogState(() => activeTabIndex = 1),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: activeTabIndex == 1 ? theme.colorScheme.primary : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Active Rules (${currentRules.length})',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: activeTabIndex == 1
                                ? (theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white)
                                : theme.colorScheme.onSurface.withOpacity(0.7),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            if (activeTabIndex == 1) ...[
              // Active Rules Manager
              if (currentRules.isEmpty)
                Container(
                  padding: const EdgeInsets.all(28),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceVariant.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: theme.colorScheme.outline.withOpacity(0.15)),
                  ),
                  child: Column(
                    children: [
                      Icon(Icons.schedule_rounded, size: 36, color: theme.colorScheme.onSurface.withOpacity(0.4)),
                      const SizedBox(height: 10),
                      Text(
                        'No scheduled protocols active.',
                        style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withOpacity(0.6)),
                      ),
                    ],
                  ),
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 340),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: currentRules.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (ctx, idx) {
                      final rule = currentRules[idx];
                      final isDueSoon = rule.nextTriggerTime.difference(DateTime.now()).inHours < 2;

                      return Card(
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      rule.title,
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                    ),
                                  ),
                                  Switch.adaptive(
                                    value: rule.isEnabled,
                                    onChanged: (val) {
                                      scheduleSvc.toggleRule(rule.id, val);
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline_rounded, size: 18, color: Colors.redAccent),
                                    tooltip: 'Delete Schedule',
                                    onPressed: () => scheduleSvc.deleteRule(rule.id),
                                  ),
                                ],
                              ),
                              Text(
                                rule.formattedTarget,
                                style: TextStyle(fontSize: 12, color: theme.colorScheme.primary),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: [
                                  Chip(
                                    visualDensity: VisualDensity.compact,
                                    label: Text(rule.frequency.displayName, style: const TextStyle(fontSize: 10)),
                                  ),
                                  Chip(
                                    visualDensity: VisualDensity.compact,
                                    label: Text(rule.formattedTiming, style: const TextStyle(fontSize: 10)),
                                  ),
                                  Chip(
                                    visualDensity: VisualDensity.compact,
                                    backgroundColor: !rule.isEnabled
                                        ? theme.colorScheme.surfaceVariant
                                        : (rule.timingMode == ScheduleTimingMode.randomWindow
                                            ? Colors.purple.withOpacity(0.18)
                                            : (isDueSoon ? Colors.orange.withOpacity(0.2) : theme.colorScheme.surfaceVariant)),
                                    label: Text(
                                      !rule.isEnabled
                                          ? 'Paused'
                                          : (rule.timingMode == ScheduleTimingMode.randomWindow
                                              ? 'Surprise Window Active'
                                              : 'Next: ${_formatTimestampHuman(rule.nextTriggerTime)}'),
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: !rule.isEnabled
                                            ? null
                                            : (rule.timingMode == ScheduleTimingMode.randomWindow
                                                ? Colors.purpleAccent
                                                : (isDueSoon ? Colors.orangeAccent : null)),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ] else ...[
              // Create Schedule Form
              if (isDirectorMode) ...[
                // Director Mode: Specific vs Random
                const Text('Directive Source', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: ChoiceChip(
                        showCheckmark: false,
                        label: const Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.shuffle_rounded, size: 16),
                              SizedBox(width: 6),
                              Text('Random Draw'),
                            ],
                          ),
                        ),
                        selected: !isSpecificOrder,
                        onSelected: (val) => setDialogState(() => isSpecificOrder = !val),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ChoiceChip(
                        showCheckmark: false,
                        label: const Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.pin_outlined, size: 16),
                              SizedBox(width: 6),
                              Text('Specific Order'),
                            ],
                          ),
                        ),
                        selected: isSpecificOrder,
                        onSelected: (val) => setDialogState(() => isSpecificOrder = val),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                if (isSpecificOrder) ...[
                  // Specific Order Selector
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: selectedPackId,
                          decoration: const InputDecoration(labelText: 'Select Pack', border: OutlineInputBorder()),
                          items: allPacks.map((p) => DropdownMenuItem(
                            value: p.id,
                            child: Text(p.title, overflow: TextOverflow.ellipsis),
                          )).toList(),
                          onChanged: (val) {
                            setDialogState(() {
                              selectedPackId = val;
                              selectedSpecificOrder = null;
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (selectedPackId != null) ...[
                    Builder(builder: (ctx) {
                      final pack = allPacks.firstWhere((p) => p.id == selectedPackId);
                      return DropdownButtonFormField<OrderItem>(
                        value: selectedSpecificOrder,
                        decoration: const InputDecoration(labelText: 'Select Directive', border: OutlineInputBorder()),
                        items: pack.orders.map((o) => DropdownMenuItem(
                          value: o,
                          child: Text('${o.title} (${o.formattedTiming}) • +${o.rewardTokens} Tok'),
                        )).toList(),
                        onChanged: (val) => setDialogState(() => selectedSpecificOrder = val),
                      );
                    }),
                  ],
                  const SizedBox(height: 12),
                ] else ...[
                  // Category & Tier Filters for Random Draw
                  _buildCategoryAndTierFilters(
                    theme: theme,
                    categories: categories,
                    selectedCategory: selectedCategory,
                    minTier: minTier,
                    maxTier: maxTier,
                    onCategoryChanged: (cat) => setDialogState(() => selectedCategory = cat),
                    onTierChanged: (min, max) => setDialogState(() {
                      minTier = min;
                      maxTier = max;
                    }),
                  ),
                  const SizedBox(height: 12),
                ],

                // Recipient Submissive Selector (Always available with Self + Paired Contacts)
                DropdownButtonFormField<PartnerContact>(
                  value: allScheduleRecipients.firstWhere(
                    (p) => p.id == selectedPartner?.id,
                    orElse: () => allScheduleRecipients.first,
                  ),
                  decoration: const InputDecoration(labelText: 'Recipient Submissive', border: OutlineInputBorder()),
                  items: allScheduleRecipients.map((p) => DropdownMenuItem(
                    value: p,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(p.isSelf ? Icons.person_rounded : Icons.person_outline_rounded, size: 16),
                        const SizedBox(width: 8),
                        Text(p.isSelf ? p.displayName : '${p.displayName} (${p.pairingCode})'),
                      ],
                    ),
                  )).toList(),
                  onChanged: (val) => setDialogState(() => selectedPartner = val),
                ),
                const SizedBox(height: 12),
              ] else ...[
                // Player Mode: Timing Mode (Specific vs Window)
                Row(
                  children: [
                    Expanded(
                      child: ChoiceChip(
                        showCheckmark: false,
                        label: const Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.access_time_rounded, size: 16),
                              SizedBox(width: 6),
                              Text('Specific Time'),
                            ],
                          ),
                        ),
                        selected: timingMode == ScheduleTimingMode.specificTime,
                        onSelected: (val) => setDialogState(() => timingMode = ScheduleTimingMode.specificTime),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ChoiceChip(
                        showCheckmark: false,
                        label: const Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.hourglass_empty_rounded, size: 16),
                              SizedBox(width: 6),
                              Text('Random Window'),
                            ],
                          ),
                        ),
                        selected: timingMode == ScheduleTimingMode.randomWindow,
                        onSelected: (val) => setDialogState(() => timingMode = ScheduleTimingMode.randomWindow),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Category & Tier Filters for Player
                _buildCategoryAndTierFilters(
                  theme: theme,
                  categories: categories,
                  selectedCategory: selectedCategory,
                  minTier: minTier,
                  maxTier: maxTier,
                  onCategoryChanged: (cat) => setDialogState(() => selectedCategory = cat),
                  onTierChanged: (min, max) => setDialogState(() {
                    minTier = min;
                    maxTier = max;
                  }),
                ),
                const SizedBox(height: 12),
              ],

              // Timing Configuration Section
              if (timingMode == ScheduleTimingMode.specificTime) ...[
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.calendar_today_rounded, size: 16),
                        label: Text('${scheduledDate.month}/${scheduledDate.day}/${scheduledDate.year}'),
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: scheduledDate,
                            firstDate: DateTime.now().subtract(const Duration(days: 1)),
                            lastDate: DateTime.now().add(const Duration(days: 365)),
                          );
                          if (picked != null) {
                            setDialogState(() => scheduledDate = picked);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.access_time_rounded, size: 16),
                        label: Text(scheduledTime.format(context)),
                        onPressed: () async {
                          final picked = await showTimePicker(
                            context: context,
                            initialTime: scheduledTime,
                          );
                          if (picked != null) {
                            setDialogState(() => scheduledTime = picked);
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ] else ...[
                // Random Window Pickers
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.purple.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.purpleAccent.withOpacity(0.25)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.casino_rounded, size: 16, color: Colors.purpleAccent),
                          SizedBox(width: 6),
                          Text('Surprise Window Timing', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'A surprise random directive will fire at an unexpected moment between start and end times.',
                        style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.7)),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () async {
                                final picked = await showTimePicker(context: context, initialTime: windowStartTime);
                                if (picked != null) setDialogState(() => windowStartTime = picked);
                              },
                              child: Text('Start: ${windowStartTime.format(context)}'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.arrow_forward_rounded, size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () async {
                                final picked = await showTimePicker(context: context, initialTime: windowEndTime);
                                if (picked != null) setDialogState(() => windowEndTime = picked);
                              },
                              child: Text('End: ${windowEndTime.format(context)}'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),

              // Recurrence Selector
              DropdownButtonFormField<RepeatFrequency>(
                value: frequency,
                decoration: const InputDecoration(labelText: 'Repeat Recurrence', border: OutlineInputBorder()),
                items: RepeatFrequency.values.map((f) => DropdownMenuItem(
                  value: f,
                  child: Text(f.displayName),
                )).toList(),
                onChanged: (val) {
                  if (val != null) setDialogState(() => frequency = val);
                },
              ),
              const SizedBox(height: 12),

              // Protocol Label / Name (Optional)
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(
                  labelText: 'Protocol Name (Optional)',
                  hintText: 'e.g. Evening Surprise Drill / Daily Focus Check',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 18),

              // Action Buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogCtx),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: const Text('Save Schedule'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
                    ),
                    onPressed: () {
                      if (isDirectorMode && isSpecificOrder && selectedSpecificOrder == null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Please select an order to schedule.')),
                        );
                        return;
                      }

                      final exactDateTime = DateTime(
                        scheduledDate.year,
                        scheduledDate.month,
                        scheduledDate.day,
                        scheduledTime.hour,
                        scheduledTime.minute,
                      );

                      final defaultTitle = isDirectorMode
                          ? (isSpecificOrder && selectedSpecificOrder != null
                              ? 'Scheduled: ${selectedSpecificOrder!.title}'
                              : 'Scheduled Random ${selectedCategory ?? "Directive"}')
                          : (timingMode == ScheduleTimingMode.randomWindow
                              ? 'Surprise Window (${windowStartTime.format(context)} – ${windowEndTime.format(context)})'
                              : 'Scheduled: ${selectedCategory ?? "Directive"} (${scheduledTime.format(context)})');

                      final title = titleCtrl.text.trim().isNotEmpty ? titleCtrl.text.trim() : defaultTitle;

                      final rule = ScheduledOrderRule(
                        title: title,
                        targetType: isDirectorMode ? ScheduleTargetType.directorDispatch : ScheduleTargetType.playerSelfDraw,
                        timingMode: timingMode,
                        frequency: frequency,
                        specificScheduledTime: exactDateTime,
                        windowStartHour: windowStartTime.hour,
                        windowStartMinute: windowStartTime.minute,
                        windowEndHour: windowEndTime.hour,
                        windowEndMinute: windowEndTime.minute,
                        isSpecificOrder: isSpecificOrder,
                        specificOrder: selectedSpecificOrder,
                        categoryFilter: selectedCategory,
                        minTier: minTier,
                        maxTier: maxTier,
                        targetPartnerId: selectedPartner?.id,
                        targetPartnerCode: selectedPartner?.pairingCode,
                        targetPartnerName: selectedPartner?.displayName,
                      );

                      scheduleSvc.addRule(rule);
                      Navigator.pop(dialogCtx);

                      final nextDesc = rule.timingMode == ScheduleTimingMode.randomWindow
                          ? 'Surprise window active (${windowStartTime.format(context)} – ${windowEndTime.format(context)})'
                          : 'Next trigger: ${_formatTimestampHuman(rule.nextTriggerTime)}';

                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Saved schedule "$title"! $nextDesc'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  static Widget _buildCategoryAndTierFilters({
    required ThemeData theme,
    required List<String> categories,
    required String? selectedCategory,
    required int minTier,
    required int maxTier,
    required Function(String?) onCategoryChanged,
    required Function(int, int) onTierChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Category Filter (Optional)', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ChoiceChip(
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              label: const Text('All Categories'),
              selected: selectedCategory == null,
              onSelected: (val) {
                if (val) onCategoryChanged(null);
              },
            ),
            ...categories.map((cat) => ChoiceChip(
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  label: Text(cat),
                  selected: selectedCategory == cat,
                  onSelected: (val) => onCategoryChanged(val ? cat : null),
                )),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Difficulty Tier Range', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
            Text('Tier $minTier – Tier $maxTier', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: theme.colorScheme.primary)),
          ],
        ),
        RangeSlider(
          values: RangeValues(minTier.toDouble(), maxTier.toDouble()),
          min: 1,
          max: 5,
          divisions: 4,
          labels: RangeLabels('Tier $minTier', 'Tier $maxTier'),
          onChanged: (RangeValues values) {
            onTierChanged(values.start.round(), values.end.round());
          },
        ),
      ],
    );
  }

  static String _formatTimestampHuman(DateTime dt) {
    final now = DateTime.now();
    final isToday = dt.year == now.year && dt.month == now.month && dt.day == now.day;
    final isTomorrow = dt.year == now.year && dt.month == now.month && dt.day == now.day + 1;

    final hour = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final min = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    final timeStr = '$hour:$min $ampm';

    if (isToday) return 'Today at $timeStr';
    if (isTomorrow) return 'Tomorrow at $timeStr';
    return '${dt.month}/${dt.day} at $timeStr';
  }
}
