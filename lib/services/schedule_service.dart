import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import '../models/scheduled_order_rule.dart';
import '../models/order_item.dart';
import '../models/partner_contact.dart';
import '../core/notifications/notification_service.dart';
import '../core/sound/sound_service.dart';
import 'order_engine.dart';
import 'schedule_coordinator.dart';
import 'sync_service.dart';
import 'partner_service.dart';

class ScheduleService extends ChangeNotifier {
  static const String appCurrentBuildVersion = '1.1.3';

  // Valid Patreon Unlock Code hashes
  static final Set<String> _validCodeHashes = {
    _hashPasscode('PATREON-VIP'),
    _hashPasscode('QUESTS-2026'),
    _hashPasscode('DIRECTIVE-CHAIN'),
    _hashPasscode('PATREON-SUPPORTER'),
    _hashPasscode('QUEST'),
    _hashPasscode('VIP'),
    _hashPasscode('SCHEDULE'),
    _hashPasscode('SCHEDULE-VIP'),
    _hashPasscode('PATREON'),
  };

  static String _hashPasscode(String raw) {
    final clean = raw.trim().toUpperCase();
    final bytes = utf8.encode('patreon_quest_salt_v1_$clean');
    return sha256.convert(bytes).toString();
  }

  bool _isUnlocked = false;
  bool get isUnlocked => _isUnlocked;

  final List<ScheduledOrderRule> _rules = [];
  List<ScheduledOrderRule> get rules => List.unmodifiable(_rules);

  List<ScheduledOrderRule> get directorRules =>
      _rules.where((r) => r.targetType == ScheduleTargetType.directorDispatch).toList();

  List<ScheduledOrderRule> get playerRules =>
      _rules.where((r) => r.targetType == ScheduleTargetType.playerSelfDraw).toList();

  OrderEngine? _orderEngine;
  SyncService? _syncService;
  PartnerService? _partnerService;

  Timer? _tickerTimer;
  StreamSubscription? _notificationClickSub;
  bool _isDisposed = false;
  bool get isDisposed => _isDisposed;

  /// Occurrences (`<ruleId>@<trigger>`) this device has already executed.
  /// Mirrors [ScheduleCoordinator.ledgerKey] so a due rule can be claimed
  /// synchronously, which keeps `checkDueRules` usable without an await gap.
  final Set<String> _firedOccurrences = <String>{};

  /// Guards against the several callers of [checkDueRules] (10s ticker, app
  /// resume, notification tap, startup) overlapping across its await points and
  /// executing the same rule twice or clobbering each other's rule updates.
  bool _isCheckingRules = false;

  int _tickCount = 0;

  ScheduleService() {
    _initStorage();
    _startTicker();
    _listenToNotifications();
  }

  Future<void> init() async {
    await _initStorage();
  }

  /// Pulls rule state and the occurrence ledger back off disk before checking
  /// what is due.
  ///
  /// The background isolate has its own SharedPreferences cache and advances
  /// rules while the UI isolate is frozen. Without this the UI isolate would
  /// act on — and then persist — a stale snapshot, re-firing rules the
  /// background already ran and rolling back its progress.
  Future<void> resyncFromStorage() async {
    await _loadRulesFromDisk();
    await checkDueRules();
  }

  Future<void> _loadRulesFromDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      if (_isDisposed) return;

      _firedOccurrences.addAll(await ScheduleCoordinator.loadLedger(prefs));

      final savedRulesJson = prefs.getString('saved_scheduled_rules_v1');
      if (savedRulesJson == null || savedRulesJson.isEmpty) return;
      final List list = jsonDecode(savedRulesJson);
      final diskRules = list
          .map((r) => ScheduledOrderRule.fromJson(Map<String, dynamic>.from(r as Map)))
          .toList();
      _rules
        ..clear()
        ..addAll(diskRules);
      notifyListeners();
    } catch (e) {
      if (kDebugMode) print('ScheduleService: rule resync error: $e');
    }
  }

  /// Claims [rule]'s current occurrence for this isolate. Returns false when it
  /// has already been executed (by an earlier pass, or by the background
  /// isolate while the app was asleep).
  bool _claimOccurrence(ScheduledOrderRule rule) {
    final key = ScheduleCoordinator.occurrenceKey(rule.id, rule.nextTriggerTime);
    if (_firedOccurrences.contains(key)) return false;
    _firedOccurrences.add(key);
    // Persist opportunistically; the in-memory mirror is what makes the claim
    // synchronous, and a lost write only risks a duplicate, never a drop.
    SharedPreferences.getInstance()
        .then((prefs) => ScheduleCoordinator.recordOccurrences(prefs, [key]))
        .catchError((_) {});
    return true;
  }

  @override
  void notifyListeners() {
    if (_isDisposed) return;
    super.notifyListeners();
  }

  void _listenToNotifications() {
    _notificationClickSub?.cancel();
    _notificationClickSub = NotificationService.onNotificationClicked.listen((payload) {
      if (payload.startsWith('rule:')) {
        checkDueRules();
      }
    });
  }

  void attachDependencies({
    required OrderEngine orderEngine,
    required SyncService syncService,
    required PartnerService partnerService,
  }) {
    _orderEngine = orderEngine;
    _syncService = syncService;
    _partnerService = partnerService;

    // Ensure all enabled rules have staged orders drawn and exact alarms armed
    _ensureRulesStagedAndArmed();

    // Check due rules immediately upon app startup/resume
    checkDueRules();
  }

  Future<void> _ensureRulesStagedAndArmed() async {
    final changed = <String>{};
    for (int i = 0; i < _rules.length; i++) {
      final r = _rules[i];
      if (r.isEnabled) {
        if (r.stagedOrder == null) {
          final staged = _drawStagedOrderForRule(r);
          if (staged != null) {
            _rules[i] = r.copyWith(stagedOrder: staged);
            changed.add(r.id);
          }
        }
        if (r.nextTriggerTime.isAfter(DateTime.now())) {
          NotificationService.scheduleOrderNotification(_rules[i]);
        }
      }
    }
    if (changed.isNotEmpty) {
      await _saveToStorage(changedRuleIds: changed);
      notifyListeners();
    }
  }

  Future<void> _initStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Another isolate may have advanced rules since this isolate last read
      // prefs, so always come off disk rather than the in-memory cache.
      await prefs.reload();
      if (_isDisposed) return;

      _firedOccurrences.addAll(await ScheduleCoordinator.loadLedger(prefs));

      // Check Patreon unlock status (unified with quest unlock)
      final unlockedVersion = prefs.getString('quests_unlocked_build_version');
      final generalUnlocked = prefs.getBool('patreon_vip_unlocked_v1') ?? false;
      _isUnlocked = generalUnlocked || unlockedVersion == appCurrentBuildVersion;

      // Load scheduled rules
      final savedRulesJson = prefs.getString('saved_scheduled_rules_v1');
      if (savedRulesJson != null && savedRulesJson.isNotEmpty) {
        final List list = jsonDecode(savedRulesJson);
        _rules.clear();
        _rules.addAll(
          list.map((r) => ScheduledOrderRule.fromJson(Map<String, dynamic>.from(r as Map))),
        );
        // Pre-arm native OS exact alarms for all enabled future rules with staged orders
        final changed = <String>{};
        for (int i = 0; i < _rules.length; i++) {
          final r = _rules[i];
          if (r.isEnabled) {
            if (r.stagedOrder == null) {
              final staged = _drawStagedOrderForRule(r);
              if (staged != null) {
                _rules[i] = r.copyWith(stagedOrder: staged);
                changed.add(r.id);
              }
            }
            NotificationService.scheduleOrderNotification(_rules[i]);
          }
        }
        if (changed.isNotEmpty) {
          await _saveToStorage(changedRuleIds: changed);
        }
      }
      if (_isDisposed) return;
      notifyListeners();
      if (_orderEngine != null) {
        checkDueRules();
      }
    } catch (e) {
      if (kDebugMode) print('Error loading ScheduleService storage: $e');
    }
  }

  /// Persists rules.
  ///
  /// With [changedRuleIds] the write is merged onto the current on-disk
  /// snapshot and only those rules are overwritten, so progress the background
  /// isolate made on *other* rules survives. Passing nothing performs an
  /// authoritative full replace, which is what user-driven CRUD wants.
  Future<void> _saveToStorage({Set<String>? changedRuleIds}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      List<ScheduledOrderRule> toWrite = _rules;

      if (changedRuleIds != null) {
        await prefs.reload();
        final raw = prefs.getString('saved_scheduled_rules_v1');
        final disk = <ScheduledOrderRule>[];
        if (raw != null && raw.isNotEmpty) {
          try {
            disk.addAll((jsonDecode(raw) as List).map((r) =>
                ScheduledOrderRule.fromJson(Map<String, dynamic>.from(r as Map))));
          } catch (_) {}
        }
        if (disk.isNotEmpty) {
          final mine = {for (final r in _rules) r.id: r};
          final merged = <ScheduledOrderRule>[
            for (final d in disk)
              (changedRuleIds.contains(d.id) && mine.containsKey(d.id)) ? mine[d.id]! : d,
          ];
          final diskIds = disk.map((d) => d.id).toSet();
          for (final r in _rules) {
            if (!diskIds.contains(r.id)) merged.add(r);
          }
          toWrite = merged;
          _rules
            ..clear()
            ..addAll(merged);
        }
      }

      final encoded = jsonEncode(toWrite.map((r) => r.toJson()).toList());
      await prefs.setString('saved_scheduled_rules_v1', encoded);
      await prefs.setBool('patreon_vip_unlocked_v1', _isUnlocked);
    } catch (e) {
      if (kDebugMode) print('Error saving ScheduleService storage: $e');
    }
  }

  void _startTicker() {
    _tickerTimer?.cancel();
    _tickerTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_isDisposed) return;
      _tickCount++;
      // Re-reading prefs off disk costs a platform channel round trip, so do the
      // cheap in-memory check every tick and the full cross-isolate resync
      // (plus foreground heartbeat) once a minute.
      if (_tickCount % 6 == 0) {
        markForegroundAlive();
        resyncFromStorage();
      } else {
        checkDueRules();
      }
    });
  }

  /// Tells the background isolate that the UI isolate is awake and will handle
  /// due rules itself, so the two do not race over the same occurrence.
  Future<void> markForegroundAlive() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await ScheduleCoordinator.markForegroundAlive(prefs);
    } catch (_) {}
  }

  /// Hands scheduled-rule execution back to the background isolate.
  Future<void> markForegroundStopped() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await ScheduleCoordinator.clearForegroundAlive(prefs);
    } catch (_) {}
  }

  @override
  void dispose() {
    _isDisposed = true;
    _tickerTimer?.cancel();
    _notificationClickSub?.cancel();
    super.dispose();
  }

  // ---- Patreon Code Validation ----

  bool unlockWithPasscode(String passcode) {
    final hash = _hashPasscode(passcode);
    if (_validCodeHashes.contains(hash)) {
      _isUnlocked = true;
      _saveToStorage();
      notifyListeners();
      return true;
    }
    return false;
  }

  void relock() {
    _isUnlocked = false;
    _saveToStorage();
    notifyListeners();
  }

  OrderItem? _drawStagedOrderForRule(ScheduledOrderRule rule) {
    if (rule.isSpecificOrder && rule.specificOrder != null) {
      return rule.specificOrder;
    }
    if (_orderEngine != null) {
      return _orderEngine!.drawRandomOrder(
        category: rule.categoryFilter,
        minTier: rule.minTier,
        maxTier: rule.maxTier,
      );
    }
    return null;
  }

  // ---- Rule CRUD ----

  Future<void> addRule(ScheduledOrderRule rule) async {
    var ruleToSave = rule;
    if (ruleToSave.stagedOrder == null) {
      final staged = _drawStagedOrderForRule(ruleToSave);
      if (staged != null) {
        ruleToSave = ruleToSave.copyWith(stagedOrder: staged);
      }
    }
    _rules.add(ruleToSave);
    await _saveToStorage();
    if (ruleToSave.isEnabled) {
      await NotificationService.scheduleOrderNotification(ruleToSave);
    }
    notifyListeners();
  }

  Future<void> updateRule(ScheduledOrderRule rule) async {
    final idx = _rules.indexWhere((r) => r.id == rule.id);
    if (idx >= 0) {
      var ruleToSave = rule;
      if (ruleToSave.stagedOrder == null) {
        final staged = _drawStagedOrderForRule(ruleToSave);
        if (staged != null) {
          ruleToSave = ruleToSave.copyWith(stagedOrder: staged);
        }
      }
      _rules[idx] = ruleToSave;
      await _saveToStorage();
      if (ruleToSave.isEnabled) {
        await NotificationService.scheduleOrderNotification(ruleToSave);
      } else {
        await NotificationService.cancelOrderNotification(ruleToSave.id);
      }
      notifyListeners();
    }
  }

  Future<void> toggleRule(String id, bool isEnabled) async {
    final idx = _rules.indexWhere((r) => r.id == id);
    if (idx >= 0) {
      final current = _rules[idx];
      var nextTrigger = current.nextTriggerTime;

      // If re-enabling an expired trigger, compute fresh next trigger
      if (isEnabled && nextTrigger.isBefore(DateTime.now())) {
        nextTrigger = ScheduledOrderRule.computeInitialTrigger(
          timingMode: current.timingMode,
          specificScheduledTime: current.specificScheduledTime,
          windowStartHour: current.windowStartHour,
          windowStartMinute: current.windowStartMinute,
          windowEndHour: current.windowEndHour,
          windowEndMinute: current.windowEndMinute,
        );
      }

      var staged = current.stagedOrder;
      if (isEnabled && (staged == null || nextTrigger.isBefore(DateTime.now()))) {
        staged = _drawStagedOrderForRule(current);
      }

      _rules[idx] = current.copyWith(
        isEnabled: isEnabled,
        nextTriggerTime: nextTrigger,
        stagedOrder: staged,
      );
      await _saveToStorage();
      if (isEnabled) {
        await NotificationService.scheduleOrderNotification(_rules[idx]);
      } else {
        await NotificationService.cancelOrderNotification(id);
      }
      notifyListeners();
    }
  }

  Future<void> deleteRule(String id) async {
    _rules.removeWhere((r) => r.id == id);
    await _saveToStorage();
    await NotificationService.cancelOrderNotification(id);
    notifyListeners();
  }

  // ---- Execution Engine ----

  Future<void> checkDueRules() async {
    if (_isCheckingRules) return;
    _isCheckingRules = true;
    try {
      final now = DateTime.now();
      final changedIds = <String>{};

      for (int i = 0; i < _rules.length; i++) {
        final rule = _rules[i];
        if (!rule.isEnabled) continue;
        if (now.isBefore(rule.nextTriggerTime)) continue;

        // Claim the occurrence before doing any work. If the background isolate
        // already delivered this exact firing while the device was asleep, the
        // claim fails and we only advance the schedule.
        if (_claimOccurrence(rule)) {
          await _executeRule(rule);
        }

        // Anchor the next trigger on the rule's own schedule rather than on
        // `now`, so catching up late does not also skip the next occurrence.
        final nextRecurrence = rule.computeNextRecurrenceAfter(now);
        final ScheduledOrderRule updated;
        if (nextRecurrence != null) {
          updated = rule.copyWith(
            lastTriggeredAt: now,
            nextTriggerTime: nextRecurrence,
            stagedOrder: _drawStagedOrderForRule(rule),
          );
          // Pre-arm native alarm for next recurrence
          NotificationService.scheduleOrderNotification(updated);
        } else {
          // One-shot rule: mark disabled
          updated = rule.copyWith(
            lastTriggeredAt: now,
            isEnabled: false,
            clearStagedOrder: true,
          );
          NotificationService.cancelOrderNotification(rule.id);
        }

        // Write back by id, not by index: the await above yields, and a merge
        // save can reorder or replace the list in that gap.
        final writeIndex = _rules[i].id == rule.id
            ? i
            : _rules.indexWhere((r) => r.id == rule.id);
        if (writeIndex >= 0) _rules[writeIndex] = updated;
        changedIds.add(rule.id);
      }

      if (changedIds.isNotEmpty) {
        await _saveToStorage(changedRuleIds: changedIds);
        notifyListeners();
      }
    } finally {
      _isCheckingRules = false;
    }
  }

  Future<void> _executeRule(ScheduledOrderRule rule) async {
    if (rule.targetType == ScheduleTargetType.directorDispatch) {
      await _executeDirectorDispatch(rule);
    } else {
      await _executePlayerSelfDraw(rule);
    }
  }

  Future<void> _executeDirectorDispatch(ScheduledOrderRule rule) async {
    if (_syncService == null) return;

    OrderItem? orderToDispatch = rule.stagedOrder ?? rule.specificOrder;

    if (orderToDispatch == null && _orderEngine != null) {
      orderToDispatch = _orderEngine!.drawRandomOrder(
        category: rule.categoryFilter,
        minTier: rule.minTier,
        maxTier: rule.maxTier,
      );
    }

    if (orderToDispatch == null) {
      if (kDebugMode) print('ScheduleService: No matching order found to dispatch for rule "${rule.title}"');
      return;
    }

    // Resolve target partner
    PartnerContact? targetPartner;
    if (rule.targetPartnerId == PartnerContact.selfId || rule.targetPartnerName == 'Myself (This Device)') {
      targetPartner = PartnerContact.self();
    } else if (rule.targetPartnerId != null && _partnerService != null) {
      targetPartner = _partnerService!.unblockedContacts.cast<PartnerContact?>().firstWhere(
            (p) => p?.id == rule.targetPartnerId || p?.pairingCode == rule.targetPartnerCode,
            orElse: () => null,
          );
    }
    targetPartner ??= _partnerService?.activePartner ?? PartnerContact.self();

    _syncService!.dispatchOrderToPlayer(
      orderToDispatch,
      targetPartner: targetPartner,
      assignedAt: rule.nextTriggerTime,
    );

    NotificationService.showOrderDispatchedNotification(
      title: orderToDispatch.title,
      description: orderToDispatch.description.isNotEmpty
          ? orderToDispatch.description
          : (targetPartner.isSelf
              ? 'Automated scheduled directive assigned to yourself.'
              : 'Automated dispatch sent to ${targetPartner.displayName}'),
      assignerName: targetPartner.isSelf ? 'Scheduled Directive' : 'Director Dispatch',
      rewardTokens: orderToDispatch.rewardTokens,
    );
    if (targetPartner.isSelf) {
      SoundService.playAlertSound();
    }
  }

  Future<void> _executePlayerSelfDraw(ScheduledOrderRule rule) async {
    if (_orderEngine == null) return;

    final order = rule.stagedOrder ?? rule.specificOrder ?? _orderEngine!.drawRandomOrder(
      category: rule.categoryFilter,
      minTier: rule.minTier,
      maxTier: rule.maxTier,
    );

    if (order == null) {
      if (kDebugMode) print('ScheduleService: No available orders found for player self-draw rule "${rule.title}"');
      return;
    }

    _orderEngine!.assignOrder(
      order,
      // Deterministic per-occurrence id: distinguishes two rules that happened
      // to draw the same task (which title matching would collapse into one)
      // while still deduping a single occurrence delivered from both isolates.
      id: ScheduleCoordinator.activeOrderIdFor(rule.id, rule.nextTriggerTime),
      assignedAt: rule.nextTriggerTime,
    );

    SoundService.playAlertSound();
    NotificationService.showOrderDispatchedNotification(
      title: order.title,
      description: order.description.isNotEmpty
          ? order.description
          : 'Scheduled order drawn and active on your dashboard.',
      assignerName: 'Scheduled Task',
      rewardTokens: order.rewardTokens,
    );

    _syncService?.broadcastPlayerState();
  }
}
