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
import 'push_service.dart';
import '../models/sync_message.dart';
import '../core/security/encryption_helper.dart';
import 'sync_service.dart';
import 'partner_service.dart';

class ScheduleService extends ChangeNotifier {
  static const String appCurrentBuildVersion = '1.3.4';

  /// Occurrences staged with the Worker per rule.
  ///
  /// Deliberately far larger than [NotificationService.preArmedOccurrences],
  /// which is bounded by how many OS alarm slots the app is willing to hold.
  /// A staged row costs one D1 row and nothing else, and the horizon is the
  /// only margin there is: the Worker deletes each row as it fires it and can
  /// never regenerate one, because the payload is ciphertext it cannot read.
  /// Run the queue dry and the schedule stops - silently, with the app still
  /// reporting the rule as enabled - so the horizon has to outlast any
  /// plausible stretch of the app not being opened.
  static const int stagedOccurrences = 14;

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

      // Every rule change and every execution passes through here, so this is
      // the one place that keeps the Worker's view of the schedule current.
      unawaited(uploadScheduleToRelay());
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

  /// Hands upcoming self-draw occurrences to the Worker to fire on time.
  ///
  /// The device cannot be relied upon to wake itself: on the hardware this was
  /// built against the foreground service ran nine hours then stopped ticking
  /// for six, and an exact alarm confirmed as armed was never delivered. A cron
  /// outside the device is subject to none of that.
  Future<void> uploadScheduleToRelay() async {
    await stageRulesWithWorker(_rules);
  }

  /// Rebuilds the staged schedule from whatever is on disk.
  ///
  /// Exists so the FCM background isolate can top the queue back up after a
  /// scheduled push consumes a row. That isolate has no [ScheduleService] - it
  /// has no app state at all - so this deliberately takes nothing but
  /// SharedPreferences.
  static Future<bool> restageFromStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final raw = prefs.getString('saved_scheduled_rules_v1');
      if (raw == null || raw.isEmpty) return false;
      final rules = (jsonDecode(raw) as List)
          .map((r) => ScheduledOrderRule.fromJson(Map<String, dynamic>.from(r as Map)))
          .toList();
      return await stageRulesWithWorker(rules);
    } catch (e) {
      if (kDebugMode) print('ScheduleService: restage error: $e');
      return false;
    }
  }

  /// Builds and uploads the staged schedule for [rules].
  ///
  /// Static because both callers matter and only one of them has an instance:
  /// the app when rules change, and the background isolate when a scheduled
  /// push lands.
  static Future<bool> stageRulesWithWorker(List<ScheduledOrderRule> rules) async {
    if (!PushService.canSend) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final myCode = prefs.getString('pairing_code') ?? '';
      final mySecret = prefs.getString('pairing_secret') ?? '';
      if (myCode.isEmpty) return false;

      return await PushService.stageSchedule(
        topic: SyncService.getHashedTopic(myCode),
        entries: buildStagedEntries(
          rules: rules,
          myCode: myCode,
          mySecret: mySecret,
          from: DateTime.now(),
        ),
      );
    } catch (e) {
      if (kDebugMode) print('ScheduleService: schedule upload error: $e');
      return false;
    }
  }

  /// Turns rules into the rows the Worker will replay.
  ///
  /// Each occurrence is staged as the same encrypted dispatchOrder a director
  /// would send, carrying the deterministic per-occurrence active-order id - so
  /// if the local alarm fires as well, `assignOrder` recognises the duplicate
  /// and the occurrence ledger refuses the second execution. Belt and braces,
  /// not either-or.
  ///
  /// Pure, and separated from the upload so the horizon, the addressing and the
  /// ordering can be tested without a network.
  @visibleForTesting
  static List<Map<String, dynamic>> buildStagedEntries({
    required List<ScheduledOrderRule> rules,
    required String myCode,
    required String mySecret,
    required DateTime from,
  }) {
    final entries = <Map<String, dynamic>>[];

    for (final rule in rules) {
      if (!rule.isEnabled) continue;
      // Director rules dispatch to someone else and are sent when they fire;
      // only self-draws need waking this device up.
      if (rule.targetType != ScheduleTargetType.playerSelfDraw) continue;

      final order = rule.stagedOrder ?? rule.specificOrder;
      if (order == null) continue;

      for (final trigger in rule.upcomingTriggers(stagedOccurrences, from: from)) {
        final message = SyncMessage(
          id: 'sched_${ScheduleCoordinator.occurrenceKey(rule.id, trigger)}',
          type: SyncMessageType.dispatchOrder,
          // Deliberately not this device's id or pairing code. A scheduled
          // self-draw really is "from me to me", but _isOwnMessage exists to
          // kill relay echo loops and cannot tell the two apart - staging it
          // under our own identity meant the push arrived and was discarded as
          // our own echo. Addressing still works through targetCode.
          senderId: 'scheduled',
          targetCode: myCode,
          payload: {
            'activeOrderId': ScheduleCoordinator.activeOrderIdFor(rule.id, trigger),
            'order': order.toJson(),
            'senderCode': '',
            'senderName': 'Scheduled Task',
            'assignedByDirector': false,
            'isScheduled': true,
            'assignedAt': trigger.toIso8601String(),
          },
        );

        final encoded = message.encode();
        entries.add({
          'ruleId': '${rule.id}_${trigger.millisecondsSinceEpoch}',
          'at': trigger.millisecondsSinceEpoch,
          'payload': mySecret.isNotEmpty
              ? EncryptionHelper.encryptString(encoded, mySecret)
              : encoded,
        });
      }
    }

    // Nearest occurrence first. The Worker caps how many rows one topic may
    // hold and truncates the tail; entries come out of the loop grouped by
    // rule, so unsorted they would starve a whole rule of the pair rather than
    // trimming the far end of everyone's horizon.
    entries.sort((a, b) => (a['at'] as int).compareTo(b['at'] as int));
    return entries;
  }

  /// Re-registers OS alarms for every enabled rule.
  ///
  /// Alarms were previously only armed at cold start. Android can drop pending
  /// alarms across a long idle stretch or an app update, and nothing
  /// re-established them until the process was restarted from scratch — so a
  /// rule could sit enabled for days with nothing actually queued behind it.
  /// Re-arming is idempotent for the imminent occurrence, which keeps its
  /// stored trigger time.
  Future<void> rearmAllAlarms() async {
    for (final rule in _rules) {
      if (!rule.isEnabled) continue;
      await NotificationService.scheduleOrderNotification(rule);
    }
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

    // The pre-armed OS alarm announces this occurrence at its trigger time on
    // its own. Announcing again here is what produced two notifications for a
    // single scheduled task whenever the service was awake to run the rule.
    final alreadyAnnounced = await NotificationService.alarmAlreadyAnnounced(
        rule.id, rule.nextTriggerTime);

    if (!alreadyAnnounced) {
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

    // Checked after assignOrder so the order is still mounted synchronously —
    // startup catch-up depends on that.
    final alreadyAnnounced = await NotificationService.alarmAlreadyAnnounced(
        rule.id, rule.nextTriggerTime);

    if (!alreadyAnnounced) {
      SoundService.playAlertSound();
      NotificationService.showOrderDispatchedNotification(
        title: order.title,
        description: order.description.isNotEmpty
            ? order.description
            : 'Scheduled order drawn and active on your dashboard.',
        assignerName: 'Scheduled Task',
        rewardTokens: order.rewardTokens,
      );
    }

    _syncService?.broadcastPlayerState();
  }
}
