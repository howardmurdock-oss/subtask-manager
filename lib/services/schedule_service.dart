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
import 'sync_service.dart';
import 'partner_service.dart';

class ScheduleService extends ChangeNotifier {
  static const String appCurrentBuildVersion = '1.1.0';

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

  ScheduleService() {
    _initStorage();
    _startTicker();
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
    bool needsSave = false;
    for (int i = 0; i < _rules.length; i++) {
      final r = _rules[i];
      if (r.isEnabled) {
        if (r.stagedOrder == null) {
          final staged = _drawStagedOrderForRule(r);
          if (staged != null) {
            _rules[i] = r.copyWith(stagedOrder: staged);
            needsSave = true;
          }
        }
        if (r.nextTriggerTime.isAfter(DateTime.now())) {
          NotificationService.scheduleOrderNotification(_rules[i]);
        }
      }
    }
    if (needsSave) {
      await _saveToStorage();
      notifyListeners();
    }
  }

  Future<void> _initStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();

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
        bool needsSave = false;
        for (int i = 0; i < _rules.length; i++) {
          final r = _rules[i];
          if (r.isEnabled) {
            if (r.stagedOrder == null) {
              final staged = _drawStagedOrderForRule(r);
              if (staged != null) {
                _rules[i] = r.copyWith(stagedOrder: staged);
                needsSave = true;
              }
            }
            NotificationService.scheduleOrderNotification(_rules[i]);
          }
        }
        if (needsSave) {
          await _saveToStorage();
        }
      }
      notifyListeners();
    } catch (e) {
      if (kDebugMode) print('Error loading ScheduleService storage: $e');
    }
  }

  Future<void> _saveToStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(_rules.map((r) => r.toJson()).toList());
      await prefs.setString('saved_scheduled_rules_v1', encoded);
      await prefs.setBool('patreon_vip_unlocked_v1', _isUnlocked);
    } catch (e) {
      if (kDebugMode) print('Error saving ScheduleService storage: $e');
    }
  }

  void _startTicker() {
    _tickerTimer?.cancel();
    _tickerTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      checkDueRules();
    });
  }

  @override
  void dispose() {
    _tickerTimer?.cancel();
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
    final now = DateTime.now();
    bool hasUpdates = false;

    for (int i = 0; i < _rules.length; i++) {
      final rule = _rules[i];
      if (!rule.isEnabled) continue;

      if (now.isAfter(rule.nextTriggerTime) || now.isAtSameMomentAs(rule.nextTriggerTime)) {
        await _executeRule(rule);

        final nextRecurrence = rule.computeNextRecurrence(now);
        if (nextRecurrence != null) {
          final nextStaged = _drawStagedOrderForRule(rule);
          _rules[i] = rule.copyWith(
            lastTriggeredAt: now,
            nextTriggerTime: nextRecurrence,
            stagedOrder: nextStaged,
          );
          // Pre-arm native alarm for next recurrence
          NotificationService.scheduleOrderNotification(_rules[i]);
        } else {
          // One-shot rule: mark disabled
          _rules[i] = rule.copyWith(
            lastTriggeredAt: now,
            isEnabled: false,
            clearStagedOrder: true,
          );
          NotificationService.cancelOrderNotification(rule.id);
        }
        hasUpdates = true;
      }
    }

    if (hasUpdates) {
      await _saveToStorage();
      notifyListeners();
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
