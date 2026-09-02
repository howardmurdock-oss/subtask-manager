import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/order_pack.dart';
import 'package:orders_app/models/active_order.dart';
import 'package:orders_app/models/user_stats.dart';
import 'package:orders_app/models/reward_item.dart';
import 'package:orders_app/models/reward_pack.dart';
import 'package:orders_app/models/active_redemption.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/storage_service.dart';

class MockStorageService extends StorageService {
  List<OrderPack> mockPacks = [];
  Set<String> mockEquipment = {};
  List<RewardPack> mockRewardPacks = [];
  List<RewardItem> mockRewards = [];
  List<ActiveRedemption> mockRedemptions = [];
  UserStats mockStats = UserStats(tokens: 100);

  @override
  Future<List<OrderPack>> loadPacks() async => mockPacks;

  @override
  Future<void> savePacks(List<OrderPack> packs) async {
    mockPacks = List.from(packs);
  }

  @override
  Future<List<RewardPack>> loadRewardPacks() async {
    if (mockRewardPacks.isNotEmpty) return mockRewardPacks;
    return [
      RewardPack(
        id: 'mock-pack-1',
        title: 'Mock Reward Pack',
        rewards: mockRewards,
      ),
    ];
  }

  @override
  Future<void> saveRewardPacks(List<RewardPack> packs) async {
    mockRewardPacks = List.from(packs);
  }

  @override
  Future<Set<String>> loadOwnedEquipment() async => mockEquipment;

  @override
  Future<List<ActiveOrder>> loadActiveOrders() async => [];

  @override
  Future<void> saveActiveOrders(List<ActiveOrder> orders) async {}

  @override
  Future<UserStats> loadUserStats() async => mockStats;

  @override
  Future<void> saveUserStats(UserStats stats) async {
    mockStats = stats;
  }

  @override
  Future<void> saveOwnedEquipment(Set<String> equipment) async {
    mockEquipment = Set.from(equipment);
  }

  @override
  Future<List<RewardItem>> loadRewards() async => mockRewards;

  @override
  Future<void> saveRewards(List<RewardItem> rewards) async {
    mockRewards = List.from(rewards);
  }

  @override
  Future<List<ActiveRedemption>> loadRedemptions() async => mockRedemptions;

  @override
  Future<void> saveRedemptions(List<ActiveRedemption> redemptions) async {
    mockRedemptions = List.from(redemptions);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OrderEngine Equipment Gating & Deduplication Tests', () {
    late MockStorageService mockStorage;
    late OrderEngine engine;

    setUp(() async {
      mockStorage = MockStorageService();
      mockStorage.mockPacks = [
        OrderPack(
          title: 'Specialized Gear Pack',
          orders: [
            OrderItem(
              title: 'General Task (No gear)',
              description: 'Sit upright',
              requiredEquipment: [],
            ),
            OrderItem(
              title: 'Cage & Wand Routine',
              description: 'Use vibrator on cage',
              requiredEquipment: ['Cage', 'Vibrator'],
            ),
            OrderItem(
              title: 'Blindfold Drill',
              description: 'Wear blindfold',
              requiredEquipment: ['Blindfold'],
            ),
          ],
        ),
      ];
      mockStorage.mockEquipment = {'cage'}; // Only owns 'cage' (lowercase)

      mockStorage.mockRewards = [
        RewardItem(
          id: 'test-break',
          title: '10-Min Break',
          description: 'Take a break',
          cost: 40,
          requiresDirectorApproval: false,
        ),
        RewardItem(
          id: 'test-perk',
          title: 'Special Dinner',
          description: 'Pick dinner',
          cost: 80,
          requiresDirectorApproval: true,
        ),
      ];

      engine = OrderEngine(storage: mockStorage);
      await engine.init();
    });

    test('allRequiredEquipmentAcrossPacks deduplicates case variations and prioritizes capitalized version', () async {
      // Pack 1 has 'cage' (lowercase), Pack 2 has 'Cage' (capitalized)
      final pack1 = OrderPack(
        title: 'Pack 1',
        orders: [
          OrderItem(title: 'T1', description: 'd', requiredEquipment: ['cage', 'ball gag', 'Vibrator']),
        ],
      );
      final pack2 = OrderPack(
        title: 'Pack 2',
        orders: [
          OrderItem(title: 'T2', description: 'd', requiredEquipment: ['Cage', 'Ball Gag', 'vibrator']),
        ],
      );
      mockStorage.mockPacks = [pack1, pack2];
      mockStorage.mockEquipment = {'cage'};
      await engine.init();

      final allEq = engine.allRequiredEquipmentAcrossPacks;

      // Exactly 3 unique equipment items
      expect(allEq.length, equals(3));
      // Must choose 'Cage' over 'cage'
      expect(allEq.contains('Cage'), isTrue);
      expect(allEq.contains('cage'), isFalse);
      // Must choose 'Ball Gag' over 'ball gag'
      expect(allEq.contains('Ball Gag'), isTrue);
      expect(allEq.contains('ball gag'), isFalse);
      // Must choose 'Vibrator' over 'vibrator'
      expect(allEq.contains('Vibrator'), isTrue);
      expect(allEq.contains('vibrator'), isFalse);
    });

    test('hasRequiredEquipment returns false when missing required item', () {
      final cageAndVibe = engine.packs.first.orders[1];
      final blindfold = engine.packs.first.orders[2];
      final noGear = engine.packs.first.orders[0];

      expect(engine.hasRequiredEquipment(noGear), isTrue);
      expect(engine.hasRequiredEquipment(cageAndVibe), isFalse); // Has cage, lacks vibrator
      expect(engine.hasRequiredEquipment(blindfold), isFalse); // Lacks blindfold
    });

    test('drawRandomOrder only draws orders for available equipment', () {
      for (int i = 0; i < 20; i++) {
        final drawn = engine.drawRandomOrder();
        expect(drawn, isNotNull);
        expect(drawn!.title, equals('General Task (No gear)'));
      }
    });

    test('drawRandomOrder respects minTier and maxTier bounds', () async {
      final multiTierPack = OrderPack(
        title: 'Multi-Tier Pack',
        orders: [
          OrderItem(title: 'Tier 1 Task', description: 'desc', tier: 1, requiredEquipment: []),
          OrderItem(title: 'Tier 2 Task', description: 'desc', tier: 2, requiredEquipment: []),
          OrderItem(title: 'Tier 3 Task', description: 'desc', tier: 3, requiredEquipment: []),
          OrderItem(title: 'Tier 4 Task', description: 'desc', tier: 4, requiredEquipment: []),
          OrderItem(title: 'Tier 5 Task', description: 'desc', tier: 5, requiredEquipment: []),
        ],
      );
      mockStorage.mockPacks = [multiTierPack];
      await engine.init();

      // Only Tier 3 to Tier 4
      for (int i = 0; i < 20; i++) {
        final drawn = engine.drawRandomOrder(minTier: 3, maxTier: 4);
        expect(drawn, isNotNull);
        expect(drawn!.tier, greaterThanOrEqualTo(3));
        expect(drawn.tier, lessThanOrEqualTo(4));
      }

      // Only Tier 5
      for (int i = 0; i < 10; i++) {
        final drawn = engine.drawRandomOrder(minTier: 5, maxTier: 5);
        expect(drawn, isNotNull);
        expect(drawn!.tier, equals(5));
      }

      // Out of bounds range
      final impossible = engine.drawRandomOrder(minTier: 4, maxTier: 2);
      expect(impossible, isNull);
    });

    test('drawRandomOrder excludes orders with allowRandomDraw = false', () async {
      final manualOnlyPack = OrderPack(
        title: 'Manual Only Pack',
        orders: [
          OrderItem(
            title: 'Manual Directive',
            description: 'Can only be assigned directly',
            allowRandomDraw: false,
          ),
        ],
      );
      mockStorage.mockPacks = [manualOnlyPack];
      await engine.init();

      final drawn = engine.drawRandomOrder();
      expect(drawn, isNull);
    });

    test('Toggling equipment immediately unlocks matching directives', () {
      engine.toggleEquipment('Vibrator', true);

      final cageAndVibe = engine.packs.first.orders[1];
      expect(engine.hasRequiredEquipment(cageAndVibe), isTrue);

      final drawnTitles = <String>{};
      for (int i = 0; i < 30; i++) {
        final drawn = engine.drawRandomOrder();
        if (drawn != null) drawnTitles.add(drawn.title);
      }

      expect(drawnTitles.contains('Cage & Wand Routine'), isTrue);
      expect(drawnTitles.contains('Blindfold Drill'), isFalse);
    });

    test('Reward redemption deducts tokens and creates redemption record', () {
      final breakReward = engine.rewards.first;
      expect(engine.canAfford(breakReward), isTrue);

      final success = engine.redeemReward(breakReward);
      expect(success, isTrue);
      expect(engine.stats.tokens, equals(60)); // 100 - 40
      expect(engine.redemptions.length, equals(1));
      expect(engine.redemptions.first.status, equals(RedemptionStatus.claimed));
    });

    test('Reward with approval sits in pending and refunds if rejected', () {
      final dinnerReward = engine.rewards[1]; // 80 tokens, requires approval
      final success = engine.redeemReward(dinnerReward, note: 'Italian tonight');
      expect(success, isTrue);
      expect(engine.stats.tokens, equals(20)); // 100 - 80
      expect(engine.pendingRedemptions.length, equals(1));

      // Director rejects -> refund tokens
      final redId = engine.pendingRedemptions.first.id;
      engine.rejectRedemption(redId, reason: 'Cook at home tonight');
      expect(engine.stats.tokens, equals(100)); // refunded
      expect(engine.redemptions.first.status, equals(RedemptionStatus.rejected));
    });

    test('Chastity Cage pack draw behavior and diagnostic reporting', () async {
      final chastityPack = OrderPack(
        id: '9026637b-9a56-4186-bde0-e5993c2d7ff6',
        title: 'Chastity Cage',
        isEnabled: true,
        orders: [
          OrderItem(
            id: '28c9f630-9d74-4392-a1d0-ce6ed8de9999',
            title: 'Cage Check (2 minutes)',
            description: 'Send a picture - now',
            category: 'General',
            tier: 4,
            allowRandomDraw: false,
            requiredEquipment: ['Cage'],
          ),
          OrderItem(
            id: '11ba29b6-a914-4546-835d-5ce85c5e8f1a',
            title: 'Cage Check (5 minutes)',
            description: 'Send a picture of your cage, right now.',
            category: 'General',
            tier: 3,
            allowRandomDraw: false,
            requiredEquipment: ['Cage'],
          ),
          OrderItem(
            id: '3515dfe9-6a7f-4b21-a87a-243a001cf972',
            title: 'Cage Check (10 minutes)',
            description: 'Drop whatever you are doing and take a picture.',
            category: 'General',
            tier: 2,
            allowRandomDraw: false,
            requiredEquipment: ['Cage'],
          ),
          OrderItem(
            id: '14fc3ac3-2ee6-4e58-a71b-7fb8dd764d25',
            title: 'Cage Check (15 minutes)',
            description: 'Go take a picture of your cage locked on you.',
            category: 'General',
            tier: 1,
            allowRandomDraw: false,
            requiredEquipment: ['Cage'],
          ),
          OrderItem(
            id: 'efed1947-8881-4b92-8d46-045a88c19401',
            title: 'Hygine Routine',
            description: 'Clean out your cage with soap.',
            category: 'Chastity Maintenence',
            tier: 1,
            allowRandomDraw: true,
            requiredEquipment: ['Cage'],
          ),
          OrderItem(
            id: '7d4ba6fe-02ec-4a80-b90e-cdf1473d02ed',
            title: 'Feel it',
            description: 'Spend 5 minutes in absolute silence.',
            category: 'Chastity',
            tier: 1,
            allowRandomDraw: true,
            requiredEquipment: ['Cage'],
          ),
        ],
      );

      mockStorage.mockPacks = [chastityPack];
      mockStorage.mockEquipment = {}; // No cage owned yet
      await engine.init();

      // Without Cage checked in checklist -> returns null and gives helpful reason
      final drawnWithoutCage = engine.drawRandomOrder();
      expect(drawnWithoutCage, isNull);

      final failureReason = engine.getDrawRandomOrderFailureReason();
      expect(failureReason, contains('Cage'));
      expect(failureReason, contains('Equipment Checklist'));

      // Enable Cage in equipment checklist
      engine.toggleEquipment('Cage', true);

      // Now draws only 'Hygine Routine' and 'Feel it'
      final drawnTitles = <String>{};
      for (int i = 0; i < 40; i++) {
        final drawn = engine.drawRandomOrder();
        expect(drawn, isNotNull);
        drawnTitles.add(drawn!.title);
        // Ensure manual-only orders are never drawn
        expect(drawn.title.startsWith('Cage Check'), isFalse);
      }

      expect(drawnTitles.contains('Hygine Routine'), isTrue);
      expect(drawnTitles.contains('Feel it'), isTrue);
      expect(drawnTitles.length, equals(2));
    });

    test('toggleOrderRandomDraw flips random draw state and persists', () async {
      await engine.init();
      final pack = engine.packs.first;
      final order = pack.orders.first;
      expect(order.allowRandomDraw, isTrue);

      // Toggle off
      engine.toggleOrderRandomDraw(pack.id, order.id);
      expect(engine.packs.first.orders.first.allowRandomDraw, isFalse);

      // Toggle back on
      engine.toggleOrderRandomDraw(pack.id, order.id);
      expect(engine.packs.first.orders.first.allowRandomDraw, isTrue);
    });
  });
}


