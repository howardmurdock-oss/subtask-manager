import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/order_item.dart';
import '../models/order_pack.dart';
import '../models/active_order.dart';
import '../models/user_stats.dart';
import '../models/reward_item.dart';
import '../models/reward_pack.dart';
import '../models/active_redemption.dart';

class StorageService {
  static const String _keyPacks = 'storage_order_packs';
  static const String _keyRewardPacks = 'storage_reward_packs';
  static const String _keyActiveOrders = 'storage_active_orders';
  static const String _keyUserStats = 'storage_user_stats';

  Future<List<OrderPack>> loadPacks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyPacks);
    if (raw == null || raw.isEmpty) {
      final defaults = getDefaultPacks();
      await savePacks(defaults);
      return defaults;
    }
    try {
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) => OrderPack.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return getDefaultPacks();
    }
  }

  Future<void> savePacks(List<OrderPack> packs) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(packs.map((p) => p.toJson()).toList());
    await prefs.setString(_keyPacks, raw);
  }

  Future<List<ActiveOrder>> loadActiveOrders() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyActiveOrders);
    if (raw == null || raw.isEmpty) return [];
    try {
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) => ActiveOrder.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveActiveOrders(List<ActiveOrder> orders) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(orders.map((o) => o.toJson()).toList());
    await prefs.setString(_keyActiveOrders, raw);
  }

  Future<UserStats> loadUserStats() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyUserStats);
    if (raw == null || raw.isEmpty) return UserStats();
    try {
      return UserStats.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return UserStats();
    }
  }

  Future<void> saveUserStats(UserStats stats) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(stats.toJson());
    await prefs.setString(_keyUserStats, raw);
  }

  Future<Set<String>> loadOwnedEquipment() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('storage_owned_equipment') ?? [];
    return list.map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty).toSet();
  }

  Future<void> saveOwnedEquipment(Set<String> equipment) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('storage_owned_equipment', equipment.toList());
  }

  Future<List<RewardPack>> loadRewardPacks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyRewardPacks);
    if (raw == null || raw.isEmpty) {
      // Check for legacy flat rewards to migrate
      final legacyRaw = prefs.getString('storage_rewards');
      if (legacyRaw != null && legacyRaw.isNotEmpty) {
        try {
          final List<dynamic> list = jsonDecode(legacyRaw) as List<dynamic>;
          final legacyRewards = list.map((e) => RewardItem.fromJson(e as Map<String, dynamic>)).toList();
          if (legacyRewards.isNotEmpty) {
            final migratedPack = RewardPack(
              id: 'custom-privileges-pack',
              title: 'Custom Privileges Pack',
              description: 'Imported from existing custom reward list.',
              author: 'Director',
              rewards: legacyRewards,
            );
            final packs = [migratedPack, ..._getDefaultRewardPacks()];
            await saveRewardPacks(packs);
            return packs;
          }
        } catch (_) {}
      }

      final defaults = _getDefaultRewardPacks();
      await saveRewardPacks(defaults);
      return defaults;
    }
    try {
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) => RewardPack.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return _getDefaultRewardPacks();
    }
  }

  Future<void> saveRewardPacks(List<RewardPack> packs) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(packs.map((p) => p.toJson()).toList());
    await prefs.setString(_keyRewardPacks, raw);
  }

  Future<List<RewardItem>> loadRewards() async {
    final packs = await loadRewardPacks();
    return packs.where((p) => p.isEnabled).expand((p) => p.rewards.where((r) => r.isEnabled)).toList();
  }

  Future<void> saveRewards(List<RewardItem> rewards) async {
    final packs = await loadRewardPacks();
    if (packs.isNotEmpty) {
      packs[0] = packs[0].copyWith(rewards: rewards);
      await saveRewardPacks(packs);
    }
  }

  Future<List<ActiveRedemption>> loadRedemptions() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('storage_redemptions');
    if (raw == null || raw.isEmpty) return [];
    try {
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) => ActiveRedemption.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveRedemptions(List<ActiveRedemption> redemptions) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(redemptions.map((r) => r.toJson()).toList());
    await prefs.setString('storage_redemptions', raw);
  }

  List<RewardPack> _getDefaultRewardPacks() {
    return [
      RewardPack(
        id: 'pack-core-privileges',
        title: 'Core Privileges & Passes',
        description: 'Standard daily breaks, meal selections, and task skip coupons.',
        author: 'System',
        version: '1.0.0',
        tags: ['Daily', 'Breaks', 'Privileges'],
        rewards: [
          RewardItem(
            id: 'reward-break-15',
            title: '15-Minute Free Rest Break',
            description: 'Take 15 minutes of uninterrupted relaxation or leisure time.',
            cost: 40,
            category: 'Break',
            requiresDirectorApproval: false,
          ),
          RewardItem(
            id: 'reward-dinner-pick',
            title: 'Choose Dinner / Meal Selection',
            description: 'Pick what is prepared or ordered for dinner tonight.',
            cost: 75,
            category: 'Privilege',
            requiresDirectorApproval: true,
          ),
          RewardItem(
            id: 'reward-skip-task',
            title: 'Task Pass / Skip Coupon',
            description: 'Skip one active Tier 1 or Tier 2 order without penalty.',
            cost: 60,
            category: 'Privilege',
            requiresDirectorApproval: false,
          ),
          RewardItem(
            id: 'reward-special-request',
            title: 'Special Director Request',
            description: 'Submit a custom personal request or privilege to your Director for review.',
            cost: 100,
            category: 'Custom',
            requiresDirectorApproval: true,
          ),
        ],
      ),
      RewardPack(
        id: 'pack-sensory-intimacy',
        title: 'Sensory & Intimacy Passes',
        description: 'Physical touch, massage requests, and specialized attire privileges.',
        author: 'System',
        version: '1.0.0',
        tags: ['Intimacy', 'Touch', 'Pampering'],
        rewards: [
          RewardItem(
            id: 'reward-massage-20',
            title: '20-Minute Full Massage',
            description: 'Claim a dedicated 20-minute shoulder, back, or foot massage from your partner.',
            cost: 90,
            category: 'Intimacy',
            requiresDirectorApproval: true,
          ),
          RewardItem(
            id: 'reward-outfit-pick',
            title: 'Wardrobe / Attire Choice',
            description: 'Select what you or your partner wears for the evening.',
            cost: 50,
            category: 'Privilege',
            requiresDirectorApproval: true,
          ),
          RewardItem(
            id: 'reward-morning-cuddle',
            title: 'Morning Snooze & Cuddle Pass',
            description: 'Grant an extra 20 minutes of cuddle time before starting morning routines.',
            cost: 65,
            category: 'Intimacy',
            requiresDirectorApproval: false,
          ),
        ],
      ),
      RewardPack(
        id: 'pack-leisure-media',
        title: 'Leisure & Screen Time',
        description: 'Guilt-free gaming, movie picks, and uninterrupted free time.',
        author: 'System',
        version: '1.0.0',
        tags: ['Entertainment', 'Gaming', 'Leisure'],
        rewards: [
          RewardItem(
            id: 'reward-movie-pick',
            title: 'Movie / Show Choice Pass',
            description: 'Full control over what you watch together for tonight’s media session.',
            cost: 50,
            category: 'Entertainment',
            requiresDirectorApproval: false,
          ),
          RewardItem(
            id: 'reward-gaming-hour',
            title: '1-Hour Uninterrupted Gaming / Hobby Pass',
            description: '60 minutes of uninterrupted hobby, reading, or video game time.',
            cost: 80,
            category: 'Leisure',
            requiresDirectorApproval: true,
          ),
        ],
      ),
    ];
  }

  static List<OrderPack> getDefaultPacks() {
    return [
      OrderPack(
        id: 'starter-discipline',
        title: 'Focus & Daily Discipline',
        description: 'Structured tasks for focus, cleanliness, and time management.',
        author: 'System',
        version: '1.0.0',
        tags: ['Discipline', 'Focus', 'Productivity'],
        orders: [
          OrderItem(
            title: 'Immediate Workspace Reset',
            description: 'Clear all clutter from your immediate desk, put away loose cups/trash, and wipe down your surface.',
            category: 'Discipline',
            tier: 1,
            durationType: DurationType.deadlineCountdown,
            durationMinutes: 10,
            rewardTokens: 15,
            penaltyTokens: 25,
            verificationType: VerificationType.honorCheck,
          ),
          OrderItem(
            title: 'Focused Deep Work Sprint',
            description: 'Work on your primary task with zero phone checks or tab switching.',
            category: 'Focus',
            tier: 3,
            durationType: DurationType.actionTimer,
            actionDurationSeconds: 1800, // 30 mins
            durationMinutes: 0,
            rewardTokens: 35,
            penaltyTokens: 50,
            verificationType: VerificationType.honorCheck,
          ),
          OrderItem(
            title: 'End of Day Accountability Report',
            description: 'Write a brief summary of completed accomplishments, tasks deferred, and tomorrow\'s focus.',
            category: 'Accountability',
            tier: 2,
            durationType: DurationType.dailyWindow,
            durationMinutes: 0,
            rewardTokens: 25,
            penaltyTokens: 30,
            verificationType: VerificationType.noteProof,
          ),
        ],
      ),
      OrderPack(
        id: 'starter-wellness',
        title: 'Physical Posture & Wellness',
        description: 'Posture checks, hydration, and stretching routines.',
        author: 'System',
        version: '1.0.0',
        tags: ['Posture', 'Wellness', 'Health'],
        orders: [
          OrderItem(
            title: 'Posture Correction & Wall Stand',
            description: 'Stand flat against a wall with heels, buttocks, shoulders, and head touching. Hold with composed posture.',
            category: 'Posture',
            tier: 2,
            durationType: DurationType.actionTimer,
            actionDurationSeconds: 300, // 5 mins
            durationMinutes: 0,
            rewardTokens: 10,
            penaltyTokens: 20,
            verificationType: VerificationType.honorCheck,
          ),
          OrderItem(
            title: 'Hydration & Mobility Drill',
            description: 'Drink a full 500ml glass of water and perform 20 bodyweight squats or shoulder mobility stretches.',
            category: 'Wellness',
            tier: 1,
            durationType: DurationType.instant,
            rewardTokens: 10,
            penaltyTokens: 15,
            verificationType: VerificationType.honorCheck,
          ),
        ],
      ),
    ];
  }
}
