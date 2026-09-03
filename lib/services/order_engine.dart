import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/order_item.dart';
import '../models/order_pack.dart';
import '../models/active_order.dart';
import '../models/user_stats.dart';
import '../models/reward_item.dart';
import '../models/reward_pack.dart';
import '../models/active_redemption.dart';
import '../core/sound/sound_service.dart';
import '../core/security/encryption_helper.dart';
import 'storage_service.dart';

class OrderEngine extends ChangeNotifier {
  final StorageService _storage;

  List<OrderPack> _packs = [];
  List<RewardPack> _rewardPacks = [];
  List<ActiveOrder> _activeOrders = [];
  Set<String> _ownedEquipment = {};
  List<ActiveRedemption> _redemptions = [];
  UserStats _stats = UserStats();
  Timer? _ticker;

  OrderEngine({StorageService? storage}) : _storage = storage ?? StorageService();

  List<OrderPack> get packs => _packs;
  List<RewardPack> get rewardPacks => _rewardPacks;
  List<ActiveOrder> get activeOrders => _activeOrders;
  Set<String> get ownedEquipment => _ownedEquipment;
  List<RewardItem> get rewards =>
      _rewardPacks.where((p) => p.isEnabled).expand((p) => p.rewards.where((r) => r.isEnabled)).toList();
  List<RewardItem> get allRewardsAcrossPacks =>
      _rewardPacks.expand((p) => p.rewards).toList();
  List<ActiveRedemption> get redemptions => _redemptions;
  UserStats get stats => _stats;

  List<ActiveOrder> get currentRunningOrders =>
      _activeOrders.where((o) => o.status == OrderStatus.active || o.status == OrderStatus.pending).toList();

  List<ActiveOrder> get underReviewOrders =>
      _activeOrders.where((o) => o.status == OrderStatus.underReview).toList();

  List<ActiveOrder> get completedOrders =>
      _activeOrders.where((o) => o.status == OrderStatus.completed).toList();

  List<ActiveOrder> get failedOrders =>
      _activeOrders.where((o) => o.status == OrderStatus.failed).toList();

  List<ActiveRedemption> get pendingRedemptions =>
      _redemptions.where((r) => r.status == RedemptionStatus.pending).toList();

  Future<void> init() async {
    _packs = await _storage.loadPacks();
    _rewardPacks = await _storage.loadRewardPacks();
    final loadedOrders = await _storage.loadActiveOrders();
    bool hadReplacements = false;
    _activeOrders = loadedOrders.map((active) {
      final o = active.order;
      final isPlaceholder = o.title.startsWith('Surprise Window') ||
          o.description == 'Scheduled directive ready for execution.' ||
          o.title.startsWith('Scheduled Random') ||
          o.title.startsWith('Scheduled: Scheduled');
      if (isPlaceholder) {
        hadReplacements = true;
        final genuine = drawRandomOrder(minTier: o.tier, maxTier: o.tier) ??
            drawRandomOrder() ??
            StorageService.getDefaultPacks().first.orders.first;
        return active.copyWith(order: genuine);
      }
      return active;
    }).toList();
    if (hadReplacements) {
      _storage.saveActiveOrders(_activeOrders);
    }
    _stats = await _storage.loadUserStats();
    _ownedEquipment = await _storage.loadOwnedEquipment();
    _redemptions = await _storage.loadRedemptions();
    _checkDailyStreak();
    _startTicker();
    notifyListeners();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      bool changed = false;
      final now = DateTime.now();

      for (int i = 0; i < _activeOrders.length; i++) {
        final active = _activeOrders[i];
        if (active.status == OrderStatus.active) {
          int newTimeSpent = active.timeSpentSeconds + 1;
          int newActionSeconds = active.actionSecondsRemaining;
          bool newTimerRunning = active.isActionTimerRunning;
          bool newTimerFinished = active.isActionTimerFinished;

          // Process action timer countdown if player started it
          if (active.isActionTimerRunning) {
            if (active.actionTimerEndsAt != null) {
              final diff = active.actionTimerEndsAt!.difference(now).inSeconds;
              if (diff <= 0) {
                newActionSeconds = 0;
                newTimerRunning = false;
                newTimerFinished = true;
                SoundService.playCompletionAlarm();
              } else {
                newActionSeconds = diff;
              }
            } else if (active.actionSecondsRemaining > 0) {
              newActionSeconds -= 1;
              if (newActionSeconds <= 0) {
                newActionSeconds = 0;
                newTimerRunning = false;
                newTimerFinished = true;
                SoundService.playCompletionAlarm();
              }
            }
          }

          _activeOrders[i] = active.copyWith(
            timeSpentSeconds: newTimeSpent,
            actionSecondsRemaining: newActionSeconds,
            isActionTimerRunning: newTimerRunning,
            isActionTimerFinished: newTimerFinished,
          );
          changed = true;

          // Check for deadline expiration
          if (active.expiresAt != null && now.isAfter(active.expiresAt!)) {
            if (active.order.verificationType == VerificationType.timerOnly && newTimerFinished) {
              completeOrder(active.id);
            } else {
              failOrder(active.id, reason: 'Deadline expired');
            }
            changed = true;
          }
        }
      }

      if (changed) {
        notifyListeners();
      }
    });
  }

  /// Start the player's physical action countdown timer
  void startActionTimer(String activeOrderId) {
    final index = _activeOrders.indexWhere((o) => o.id == activeOrderId);
    if (index == -1) return;
    final current = _activeOrders[index];
    final remaining = current.actionSecondsRemaining > 0
        ? current.actionSecondsRemaining
        : current.order.actionDurationSeconds;
    final endsAt = DateTime.now().add(Duration(seconds: remaining));
    _activeOrders[index] = current.copyWith(
      isActionTimerRunning: true,
      isActionTimerFinished: false,
      actionTimerEndsAt: endsAt,
      actionSecondsRemaining: remaining,
    );
    SoundService.playTick();
    _storage.saveActiveOrders(_activeOrders);
    notifyListeners();
  }

  /// Pause the player's physical action countdown timer
  void pauseActionTimer(String activeOrderId) {
    final index = _activeOrders.indexWhere((o) => o.id == activeOrderId);
    if (index == -1) return;
    final current = _activeOrders[index];
    int remaining = current.actionSecondsRemaining;
    if (current.actionTimerEndsAt != null) {
      final diff = current.actionTimerEndsAt!.difference(DateTime.now()).inSeconds;
      remaining = diff > 0 ? diff : 0;
    }
    _activeOrders[index] = current.copyWith(
      isActionTimerRunning: false,
      clearActionTimerEndsAt: true,
      actionSecondsRemaining: remaining,
    );
    _storage.saveActiveOrders(_activeOrders);
    notifyListeners();
  }

  /// Reset the player's physical action timer
  void resetActionTimer(String activeOrderId) {
    final index = _activeOrders.indexWhere((o) => o.id == activeOrderId);
    if (index == -1) return;
    final current = _activeOrders[index];
    _activeOrders[index] = current.copyWith(
      actionSecondsRemaining: current.order.actionDurationSeconds,
      isActionTimerRunning: false,
      isActionTimerFinished: false,
      clearActionTimerEndsAt: true,
    );
    _storage.saveActiveOrders(_activeOrders);
    notifyListeners();
  }

  /// Called when returning to the app (e.g. from camera, background, etc.)
  void onAppResumed() {
    final now = DateTime.now();
    bool changed = false;
    for (int i = 0; i < _activeOrders.length; i++) {
      final active = _activeOrders[i];
      if (active.status == OrderStatus.active && active.isActionTimerRunning && active.actionTimerEndsAt != null) {
        final diff = active.actionTimerEndsAt!.difference(now).inSeconds;
        if (diff <= 0) {
          _activeOrders[i] = active.copyWith(
            actionSecondsRemaining: 0,
            isActionTimerRunning: false,
            isActionTimerFinished: true,
          );
          SoundService.playCompletionAlarm();
        } else {
          _activeOrders[i] = active.copyWith(
            actionSecondsRemaining: diff,
          );
        }
        changed = true;
      }
    }
    if (changed) {
      _storage.saveActiveOrders(_activeOrders);
      notifyListeners();
    }
  }

  /// Called when the app is paused or backgrounded (e.g. navigating to camera)
  void onAppPaused() {
    _storage.saveActiveOrders(_activeOrders);
  }

  /// Check and maintain daily streak based on date
  void _checkDailyStreak() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (_stats.lastActiveDate != null) {
      final last = DateTime(
        _stats.lastActiveDate!.year,
        _stats.lastActiveDate!.month,
        _stats.lastActiveDate!.day,
      );
      final diffDays = today.difference(last).inDays;
      if (diffDays > 1) {
        // Streak lost
        _stats = _stats.copyWith(currentStreakDays: 0);
        _saveStats();
      }
    }
  }

  // Equipment & Inventory Validation
  bool hasRequiredEquipment(OrderItem order) {
    if (order.requiredEquipment.isEmpty) return true;
    for (final item in order.requiredEquipment) {
      final normalized = item.toLowerCase().trim();
      if (normalized.isNotEmpty && !_ownedEquipment.contains(normalized)) {
        return false;
      }
    }
    return true;
  }

  bool isEquipmentOwned(String equipmentName) {
    return _ownedEquipment.contains(equipmentName.toLowerCase().trim());
  }

  void toggleEquipment(String equipmentName, bool owned) {
    final normalized = equipmentName.toLowerCase().trim();
    if (normalized.isEmpty) return;
    if (owned) {
      _ownedEquipment.add(normalized);
    } else {
      _ownedEquipment.remove(normalized);
    }
    _storage.saveOwnedEquipment(_ownedEquipment);
    notifyListeners();
  }

  void addCustomEquipment(String equipmentName) {
    toggleEquipment(equipmentName, true);
  }

  void removeCustomEquipment(String equipmentName) {
    toggleEquipment(equipmentName, false);
  }

  static bool _shouldPreferCapitalization(String candidate, String existing) {
    if (candidate.isEmpty) return false;
    if (existing.isEmpty) return true;

    final candidateStartsUpper = candidate[0].toUpperCase() == candidate[0] && candidate[0].toLowerCase() != candidate[0];
    final existingStartsUpper = existing[0].toUpperCase() == existing[0] && existing[0].toLowerCase() != existing[0];

    if (candidateStartsUpper && !existingStartsUpper) return true;
    if (!candidateStartsUpper && existingStartsUpper) return false;

    // Count uppercase letters
    int countUpper(String s) => s.runes.where((r) => r >= 65 && r <= 90).length;
    final cCount = countUpper(candidate);
    final eCount = countUpper(existing);
    if (cCount != eCount) return cCount > eCount;

    return candidate.length < existing.length;
  }

  List<String> get allRequiredEquipmentAcrossPacks {
    final map = <String, String>{};

    void recordEquipment(String raw) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return;
      final key = trimmed.toLowerCase();

      final autoCapitalized = trimmed[0].toUpperCase() + trimmed.substring(1);
      final preferredCandidate = _shouldPreferCapitalization(trimmed, autoCapitalized) ? trimmed : autoCapitalized;

      if (!map.containsKey(key)) {
        map[key] = preferredCandidate;
      } else {
        final current = map[key]!;
        if (_shouldPreferCapitalization(trimmed, current)) {
          map[key] = trimmed;
        } else if (_shouldPreferCapitalization(preferredCandidate, current)) {
          map[key] = preferredCandidate;
        }
      }
    }

    for (final pack in _packs) {
      for (final order in pack.orders) {
        for (final eq in order.requiredEquipment) {
          recordEquipment(eq);
        }
      }
    }

    for (final owned in _ownedEquipment) {
      recordEquipment(owned);
    }

    final list = map.values.toList();
    list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  /// Pull a random order from enabled packs with category, tier range, and equipment filters
  OrderItem? drawRandomOrder({String? category, int? minTier, int? maxTier}) {
    final availableOrders = <OrderItem>[];
    for (final pack in _packs.where((p) => p.isEnabled)) {
      for (final order in pack.orders) {
        // Check if excluded from random deck draws
        if (!order.allowRandomDraw) {
          continue;
        }
        final isAll = category == null || category.isEmpty || category.trim().toLowerCase() == 'all';
        if (!isAll && order.category.trim().toLowerCase() != category!.trim().toLowerCase()) {
          continue;
        }
        if (minTier != null && order.tier < minTier) {
          continue;
        }
        if (maxTier != null && order.tier > maxTier) {
          continue;
        }
        // Check equipment availability
        if (!hasRequiredEquipment(order)) {
          continue;
        }
        // Check cooldown
        if (!_isOrderInCooldown(order)) {
          availableOrders.add(order);
        }
      }
    }

    if (availableOrders.isEmpty) return null;
    final random = Random();
    return availableOrders[random.nextInt(availableOrders.length)];
  }

  /// Returns a detailed user-friendly reason if drawRandomOrder returns null
  String? getDrawRandomOrderFailureReason({String? category, int? minTier, int? maxTier}) {
    final enabledPacks = _packs.where((p) => p.isEnabled).toList();
    if (enabledPacks.isEmpty) {
      return 'No task packs are currently enabled. Enable at least one pack in the Pack Manager.';
    }

    final allOrders = enabledPacks.expand((p) => p.orders).toList();
    if (allOrders.isEmpty) {
      return 'Enabled task packs do not contain any directives.';
    }

    final randomEligible = allOrders.where((o) => o.allowRandomDraw).toList();
    if (randomEligible.isEmpty) {
      return 'All directives in enabled packs have "Include in Random Draws" disabled.';
    }

    final isAll = category == null || category.isEmpty || category.trim().toLowerCase() == 'all';
    final categoryFiltered = !isAll
        ? randomEligible.where((o) => o.category.trim().toLowerCase() == category!.trim().toLowerCase()).toList()
        : randomEligible;
    if (categoryFiltered.isEmpty) {
      return 'No random-draw directives match category "$category".';
    }

    final tierFiltered = categoryFiltered.where((o) {
      if (minTier != null && o.tier < minTier) return false;
      if (maxTier != null && o.tier > maxTier) return false;
      return true;
    }).toList();
    if (tierFiltered.isEmpty) {
      final tierStr = minTier == maxTier ? 'Tier $minTier' : 'Tier $minTier–Tier $maxTier';
      return 'No directives match the selected difficulty ($tierStr).';
    }

    final equipmentMissing = <String>{};
    final equipmentFiltered = tierFiltered.where((o) {
      final hasEq = hasRequiredEquipment(o);
      if (!hasEq) {
        for (final eq in o.requiredEquipment) {
          if (!isEquipmentOwned(eq)) {
            equipmentMissing.add(eq);
          }
        }
      }
      return hasEq;
    }).toList();

    if (equipmentFiltered.isEmpty) {
      final missingList = equipmentMissing.join(', ');
      return 'Directives require equipment ($missingList) that is not enabled in your Equipment Checklist.';
    }

    final cooldownFiltered = equipmentFiltered.where((o) => !_isOrderInCooldown(o)).toList();
    if (cooldownFiltered.isEmpty) {
      return 'All matching directives are currently in cooldown.';
    }

    return null;
  }

  bool _isOrderInCooldown(OrderItem order) {
    if (order.cooldownHours <= 0) return false;
    final cooldownDuration = Duration(hours: order.cooldownHours);
    final now = DateTime.now();

    for (final active in _activeOrders) {
      if (active.order.id == order.id && active.completedAt != null) {
        if (now.difference(active.completedAt!) < cooldownDuration) {
          return true;
        }
      }
    }
    return false;
  }

  /// Assign and start an order
  ActiveOrder assignOrder(
    OrderItem order, {
    String? id,
    bool assignedByDirector = false,
    String? assignedByPartnerCode,
    String? assignedByPartnerId,
    String? assignedByPartnerName,
  }) {
    // 1. If an active order with this exact ID already exists, return it without resetting timer
    if (id != null && id.isNotEmpty) {
      final existingIndex = _activeOrders.indexWhere((o) => o.id == id);
      if (existingIndex != -1) {
        return _activeOrders[existingIndex];
      }
    }

    // 2. Also check if an identical directive is currently active, pending, under review, or completed
    for (final existing in _activeOrders) {
      final matchesOrder = (order.id.isNotEmpty && (existing.id == order.id || existing.order.id == order.id)) ||
          existing.order.title.trim().toLowerCase() == order.title.trim().toLowerCase();
      final isLive = existing.status == OrderStatus.active ||
          existing.status == OrderStatus.pending ||
          existing.status == OrderStatus.underReview;
      if (matchesOrder && isLive) {
        return existing;
      }
      if (matchesOrder && existing.status == OrderStatus.completed) {
        // Directive was already completed — prevent duplicate reassignment loop
        return existing;
      }
    }

    // Intercept and sanitize any placeholder tasks created by stale background handlers
    final isPlaceholder = order.title.startsWith('Surprise Window') ||
        order.description == 'Scheduled directive ready for execution.' ||
        order.title.startsWith('Scheduled Random') ||
        order.title.startsWith('Scheduled: Scheduled');
    if (isPlaceholder) {
      final genuine = drawRandomOrder(minTier: order.tier, maxTier: order.tier) ??
          drawRandomOrder() ??
          StorageService.getDefaultPacks().first.orders.first;
      order = genuine;
    }

    DateTime? expires;
    if ((order.durationType == DurationType.deadlineCountdown || order.durationType == DurationType.actionWithDeadline) &&
        order.durationMinutes > 0) {
      expires = DateTime.now().add(Duration(minutes: order.durationMinutes));
    } else if (order.durationType == DurationType.dailyWindow) {
      final now = DateTime.now();
      expires = DateTime(now.year, now.month, now.day, 23, 59, 59);
    }

    final activeOrder = ActiveOrder(
      id: id,
      order: order,
      assignedAt: DateTime.now(),
      expiresAt: expires,
      status: OrderStatus.active,
      assignedByDirector: assignedByDirector,
      assignedByPartnerCode: assignedByPartnerCode,
      assignedByPartnerId: assignedByPartnerId,
      assignedByPartnerName: assignedByPartnerName,
      actionSecondsRemaining: order.actionDurationSeconds,
    );

    _activeOrders.insert(0, activeOrder);
    _storage.saveActiveOrders(_activeOrders);
    notifyListeners();
    return activeOrder;
  }

  /// Complete an order (or submit for review)
  void submitOrCompleteOrder(String activeOrderId, {String? proofNote, String? proofImageBase64}) {
    final index = _activeOrders.indexWhere((o) => o.id == activeOrderId);
    if (index == -1) return;
    final active = _activeOrders[index];

    if (active.assignedByDirector ||
        active.order.verificationType == VerificationType.noteProof ||
        active.order.verificationType == VerificationType.photoProof ||
        proofImageBase64 != null) {
      // Moves to under review
      _activeOrders[index] = active.copyWith(
        status: OrderStatus.underReview,
        submissionProof: proofNote,
        proofImageBase64: proofImageBase64,
      );
      _storage.saveActiveOrders(_activeOrders);
      notifyListeners();
    } else {
      // Auto-complete immediately
      completeOrder(activeOrderId, proofNote: proofNote);
    }
  }

  /// Mark order as completed & award tokens
  void completeOrder(String activeOrderId, {String? proofNote}) {
    final index = _activeOrders.indexWhere((o) => o.id == activeOrderId);
    if (index == -1) return;
    final active = _activeOrders[index];

    final reward = active.order.rewardTokens;
    final now = DateTime.now();

    _activeOrders[index] = active.copyWith(
      status: OrderStatus.completed,
      completedAt: now,
      submissionProof: proofNote ?? active.submissionProof,
    );

    // Update stats
    final today = DateTime(now.year, now.month, now.day);
    bool incrementStreak = false;
    if (_stats.lastActiveDate == null) {
      incrementStreak = true;
    } else {
      final last = DateTime(
        _stats.lastActiveDate!.year,
        _stats.lastActiveDate!.month,
        _stats.lastActiveDate!.day,
      );
      if (today.difference(last).inDays >= 1) {
        incrementStreak = true;
      }
    }

    final newStreak = incrementStreak ? _stats.currentStreakDays + 1 : _stats.currentStreakDays;
    final bestStreak = max(newStreak, _stats.bestStreakDays);

    final logEntry = DisciplineLogEntry(
      id: active.id,
      orderTitle: active.order.title,
      category: active.order.category,
      tier: active.order.tier,
      tokenDelta: reward,
      isSuccess: true,
      reason: 'Order completed successfully',
      timestamp: now,
    );

    final updatedHistory = List<DisciplineLogEntry>.from(_stats.history)..insert(0, logEntry);

    _stats = _stats.copyWith(
      tokens: _stats.tokens + reward,
      totalCompleted: _stats.totalCompleted + 1,
      currentStreakDays: newStreak,
      bestStreakDays: bestStreak,
      lastActiveDate: now,
      history: updatedHistory,
    );

    _storage.saveActiveOrders(_activeOrders);
    _saveStats();
    notifyListeners();
  }

  /// Mark order as failed & penalize tokens
  void failOrder(String activeOrderId, {String reason = 'Failed / Forfeited'}) {
    final index = _activeOrders.indexWhere((o) => o.id == activeOrderId);
    if (index == -1) return;
    final active = _activeOrders[index];

    final penalty = active.order.penaltyTokens;
    final now = DateTime.now();

    _activeOrders[index] = active.copyWith(
      status: OrderStatus.failed,
      completedAt: now,
      directorNote: reason,
    );

    final logEntry = DisciplineLogEntry(
      id: active.id,
      orderTitle: active.order.title,
      category: active.order.category,
      tier: active.order.tier,
      tokenDelta: -penalty,
      isSuccess: false,
      reason: reason,
      timestamp: now,
    );

    final updatedHistory = List<DisciplineLogEntry>.from(_stats.history)..insert(0, logEntry);

    _stats = _stats.copyWith(
      tokens: max(0, _stats.tokens - penalty),
      totalFailed: _stats.totalFailed + 1,
      history: updatedHistory,
    );

    _storage.saveActiveOrders(_activeOrders);
    _saveStats();
    notifyListeners();
  }

  /// Director approves submitted proof
  void approveProof(String activeOrderId, {String? directorNote}) {
    final index = _activeOrders.indexWhere((o) => o.id == activeOrderId);
    if (index == -1) return;
    final active = _activeOrders[index];
    _activeOrders[index] = active.copyWith(directorNote: directorNote);
    completeOrder(activeOrderId);
  }

  /// Director rejects submitted proof and returns directive back to active queue
  void returnProofToQueue(String activeOrderId, {String reason = 'Returned by Director to try again'}) {
    final index = _activeOrders.indexWhere((o) => o.id == activeOrderId);
    if (index == -1) return;
    final active = _activeOrders[index];

    _activeOrders[index] = active.returnedToQueue(reason: reason);
    _storage.saveActiveOrders(_activeOrders);
    notifyListeners();
  }

  /// Director rejects submitted proof
  void rejectProof(String activeOrderId, {String reason = 'Proof rejected by Director', bool penalize = true}) {
    if (penalize) {
      failOrder(activeOrderId, reason: reason);
    } else {
      returnProofToQueue(activeOrderId, reason: reason);
    }
  }

  /// Remove an active order directly (e.g. recalled by Director)
  void removeActiveOrder(String activeOrderId) {
    _activeOrders.removeWhere((o) => o.id == activeOrderId);
    _storage.saveActiveOrders(_activeOrders);
    notifyListeners();
  }

  /// Adjust tokens directly (e.g. manual director reward/punishment)
  void adjustTokens(int delta, String reason) {
    final now = DateTime.now();
    final logEntry = DisciplineLogEntry(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      orderTitle: 'Manual Adjustment',
      category: 'Authority',
      tier: 1,
      tokenDelta: delta,
      isSuccess: delta >= 0,
      reason: reason,
      timestamp: now,
    );

    final updatedHistory = List<DisciplineLogEntry>.from(_stats.history)..insert(0, logEntry);

    _stats = _stats.copyWith(
      tokens: max(0, _stats.tokens + delta),
      history: updatedHistory,
    );

    _saveStats();
    notifyListeners();
  }

  // Privilege & Reward Shop
  bool canAfford(RewardItem reward) {
    return _stats.tokens >= reward.cost;
  }

  bool redeemReward(RewardItem reward, {String? note}) {
    if (!canAfford(reward)) return false;

    final now = DateTime.now();
    final isPending = reward.requiresDirectorApproval;

    // Deduct tokens
    final logEntry = DisciplineLogEntry(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      orderTitle: 'Redeemed: ${reward.title}',
      category: 'Reward',
      tier: 1,
      tokenDelta: -reward.cost,
      isSuccess: true,
      reason: isPending ? 'Privilege requested (Pending approval)' : 'Privilege claimed',
      timestamp: now,
    );

    final updatedHistory = List<DisciplineLogEntry>.from(_stats.history)..insert(0, logEntry);
    _stats = _stats.copyWith(
      tokens: max(0, _stats.tokens - reward.cost),
      history: updatedHistory,
    );
    _saveStats();

    final redemption = ActiveRedemption(
      reward: reward,
      requestedAt: now,
      status: isPending ? RedemptionStatus.pending : RedemptionStatus.claimed,
      note: note,
    );

    _redemptions.insert(0, redemption);
    _storage.saveRedemptions(_redemptions);
    notifyListeners();
    return true;
  }

  void approveRedemption(String redemptionId, {String? directorNote}) {
    final index = _redemptions.indexWhere((r) => r.id == redemptionId);
    if (index == -1) return;
    _redemptions[index] = _redemptions[index].copyWith(
      status: RedemptionStatus.approved,
      resolvedAt: DateTime.now(),
      directorNote: directorNote,
    );
    _storage.saveRedemptions(_redemptions);
    notifyListeners();
  }

  void rejectRedemption(String redemptionId, {String reason = 'Declined by Director'}) {
    final index = _redemptions.indexWhere((r) => r.id == redemptionId);
    if (index == -1) return;
    final redemption = _redemptions[index];

    // Refund tokens
    adjustTokens(redemption.reward.cost, 'Refund for declined: ${redemption.reward.title}');

    _redemptions[index] = redemption.copyWith(
      status: RedemptionStatus.rejected,
      resolvedAt: DateTime.now(),
      directorNote: reason,
    );
    _storage.saveRedemptions(_redemptions);
    notifyListeners();
  }

  // Reward & RewardPack Management
  void addRewardPack(RewardPack pack) {
    _rewardPacks.add(pack);
    _storage.saveRewardPacks(_rewardPacks);
    notifyListeners();
  }

  void updateRewardPack(RewardPack pack) {
    final index = _rewardPacks.indexWhere((p) => p.id == pack.id);
    if (index != -1) {
      _rewardPacks[index] = pack;
      _storage.saveRewardPacks(_rewardPacks);
      notifyListeners();
    }
  }

  void deleteRewardPack(String packId) {
    _rewardPacks.removeWhere((p) => p.id == packId);
    _storage.saveRewardPacks(_rewardPacks);
    notifyListeners();
  }

  void toggleRewardPackEnabled(String packId) {
    final index = _rewardPacks.indexWhere((p) => p.id == packId);
    if (index != -1) {
      _rewardPacks[index] = _rewardPacks[index].copyWith(isEnabled: !_rewardPacks[index].isEnabled);
      _storage.saveRewardPacks(_rewardPacks);
      notifyListeners();
    }
  }

  void addReward(RewardItem reward, {String? packId}) {
    if (_rewardPacks.isEmpty) {
      _rewardPacks.add(RewardPack(
        title: 'Custom Privileges',
        description: 'Custom added rewards',
        rewards: [reward],
      ));
    } else {
      final targetPackIndex = packId != null
          ? _rewardPacks.indexWhere((p) => p.id == packId)
          : 0;
      final idx = targetPackIndex != -1 ? targetPackIndex : 0;
      final updatedRewards = List<RewardItem>.from(_rewardPacks[idx].rewards)..add(reward);
      _rewardPacks[idx] = _rewardPacks[idx].copyWith(rewards: updatedRewards);
    }
    _storage.saveRewardPacks(_rewardPacks);
    notifyListeners();
  }

  void updateReward(RewardItem reward) {
    for (int i = 0; i < _rewardPacks.length; i++) {
      final rIndex = _rewardPacks[i].rewards.indexWhere((r) => r.id == reward.id);
      if (rIndex != -1) {
        final updated = List<RewardItem>.from(_rewardPacks[i].rewards);
        updated[rIndex] = reward;
        _rewardPacks[i] = _rewardPacks[i].copyWith(rewards: updated);
        _storage.saveRewardPacks(_rewardPacks);
        notifyListeners();
        return;
      }
    }
  }

  void deleteReward(String rewardId) {
    for (int i = 0; i < _rewardPacks.length; i++) {
      final rIndex = _rewardPacks[i].rewards.indexWhere((r) => r.id == rewardId);
      if (rIndex != -1) {
        final updated = List<RewardItem>.from(_rewardPacks[i].rewards)..removeAt(rIndex);
        _rewardPacks[i] = _rewardPacks[i].copyWith(rewards: updated);
        _storage.saveRewardPacks(_rewardPacks);
        notifyListeners();
        return;
      }
    }
  }

  // Pack Management
  void addPack(OrderPack pack) {
    _packs.add(pack);
    _storage.savePacks(_packs);
    notifyListeners();
  }

  void updatePack(OrderPack pack) {
    final index = _packs.indexWhere((p) => p.id == pack.id);
    if (index != -1) {
      _packs[index] = pack;
      _storage.savePacks(_packs);
      notifyListeners();
    }
  }

  void deletePack(String packId) {
    _packs.removeWhere((p) => p.id == packId);
    _storage.savePacks(_packs);
    notifyListeners();
  }

  void togglePackEnabled(String packId) {
    final index = _packs.indexWhere((p) => p.id == packId);
    if (index != -1) {
      _packs[index] = _packs[index].copyWith(isEnabled: !_packs[index].isEnabled);
      _storage.savePacks(_packs);
      notifyListeners();
    }
  }

  bool isOrderPackInstalled(String packId, {String? title}) {
    return _packs.any((p) => p.id == packId || (title != null && p.title.toLowerCase() == title.toLowerCase()));
  }

  bool isRewardPackInstalled(String packId, {String? title}) {
    return _rewardPacks.any((p) => p.id == packId || (title != null && p.title.toLowerCase() == title.toLowerCase()));
  }

  OrderPack importOrderPackFromJson(String rawJson, [String? password]) {
    String jsonString = rawJson.trim();
    if (password != null && password.isNotEmpty) {
      jsonString = EncryptionHelper.decryptString(jsonString, password);
    }
    final pack = OrderPack.fromJson(jsonDecode(jsonString));
    final existingIdx = _packs.indexWhere((p) => p.id == pack.id || p.title.toLowerCase() == pack.title.toLowerCase());
    if (existingIdx != -1) {
      _packs[existingIdx] = pack;
    } else {
      _packs.add(pack);
    }
    _storage.savePacks(_packs);
    notifyListeners();
    return pack;
  }

  RewardPack importRewardPackFromJson(String rawJson, [String? password]) {
    String jsonString = rawJson.trim();
    if (password != null && password.isNotEmpty) {
      jsonString = EncryptionHelper.decryptString(jsonString, password);
    }
    final pack = RewardPack.fromJson(jsonDecode(jsonString));
    final existingIdx = _rewardPacks.indexWhere((p) => p.id == pack.id || p.title.toLowerCase() == pack.title.toLowerCase());
    if (existingIdx != -1) {
      _rewardPacks[existingIdx] = pack;
    } else {
      _rewardPacks.add(pack);
    }
    _storage.saveRewardPacks(_rewardPacks);
    notifyListeners();
    return pack;
  }

  /// Toggle an individual directive's allowRandomDraw state within a pack
  void toggleOrderRandomDraw(String packId, String orderId) {
    final pIndex = _packs.indexWhere((p) => p.id == packId);
    if (pIndex != -1) {
      final oIndex = _packs[pIndex].orders.indexWhere((o) => o.id == orderId);
      if (oIndex != -1) {
        final currentOrder = _packs[pIndex].orders[oIndex];
        final updatedOrder = currentOrder.copyWith(allowRandomDraw: !currentOrder.allowRandomDraw);
        final updatedOrders = List<OrderItem>.from(_packs[pIndex].orders);
        updatedOrders[oIndex] = updatedOrder;
        _packs[pIndex] = _packs[pIndex].copyWith(orders: updatedOrders);
        _storage.savePacks(_packs);
        notifyListeners();
      }
    }
  }

  /// Dismiss/remove a specific active or review order from dashboard
  void dismissOrDeleteOrder(String activeOrderId) {
    _activeOrders.removeWhere((o) => o.id == activeOrderId);
    _storage.saveActiveOrders(_activeOrders);
    notifyListeners();
  }

  /// Clear all completed, failed, and cancelled orders
  void clearAllFinishedAndFailedOrders() {
    _activeOrders.removeWhere((o) =>
        o.status == OrderStatus.completed ||
        o.status == OrderStatus.failed ||
        o.status == OrderStatus.cancelled);
    _storage.saveActiveOrders(_activeOrders);
    notifyListeners();
  }

  /// Emergency clear all running and under review orders (clears dashboard)
  void clearAllActiveOrders() {
    _activeOrders.clear();
    _storage.saveActiveOrders(_activeOrders);
    notifyListeners();
  }

  void _saveStats() {
    _storage.saveUserStats(_stats);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}
