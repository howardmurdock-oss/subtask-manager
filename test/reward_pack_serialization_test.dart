import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/models/reward_item.dart';
import 'package:orders_app/models/reward_pack.dart';
import 'package:orders_app/core/security/encryption_helper.dart';
import 'dart:convert';

void main() {
  group('RewardPack Model & Serialization Tests', () {
    test('RewardPack json round-trip with multiple reward items', () {
      final pack = RewardPack(
        id: 'test-reward-pack-1',
        title: 'Sensory & Intimacy Pack',
        description: 'Custom intimacy perks and passes.',
        author: 'Director',
        version: '1.2.0',
        isEnabled: true,
        tags: ['Intimacy', 'Touch'],
        rewards: [
          RewardItem(
            id: 'reward-massage-30',
            title: '30-Min Shoulder Massage',
            description: 'Uninterrupted shoulder and neck rub.',
            cost: 85,
            category: 'Intimacy',
            requiresDirectorApproval: true,
            isEnabled: true,
          ),
          RewardItem(
            id: 'reward-free-snack',
            title: 'Cheat Snack Pass',
            description: 'Enjoy a dessert or snack of choice.',
            cost: 45,
            category: 'Privilege',
            requiresDirectorApproval: false,
            isEnabled: true,
          ),
        ],
      );

      final json = pack.toJson();
      final reconstructed = RewardPack.fromJson(json);

      expect(reconstructed.id, equals(pack.id));
      expect(reconstructed.title, equals(pack.title));
      expect(reconstructed.description, equals(pack.description));
      expect(reconstructed.author, equals(pack.author));
      expect(reconstructed.version, equals('1.2.0'));
      expect(reconstructed.isEnabled, isTrue);
      expect(reconstructed.tags, equals(['Intimacy', 'Touch']));
      expect(reconstructed.rewards.length, equals(2));

      final firstReward = reconstructed.rewards.first;
      expect(firstReward.title, equals('30-Min Shoulder Massage'));
      expect(firstReward.cost, equals(85));
      expect(firstReward.requiresDirectorApproval, isTrue);
    });

    test('RewardPack password encryption and decryption round-trip', () {
      final pack = RewardPack(
        title: 'Secret Special Pack',
        description: 'Encrypted rewards file',
        rewards: [
          RewardItem(
            title: 'VIP Weekend Pass',
            description: 'Complete freedom for 2 days',
            cost: 500,
          ),
        ],
      );

      final rawJson = jsonEncode(pack.toJson());
      const password = 'MySecurePassphrase123!';

      final encrypted = EncryptionHelper.encryptString(rawJson, password);
      expect(encrypted.contains('Secret Special Pack'), isFalse);

      final decrypted = EncryptionHelper.decryptString(encrypted, password);
      final parsed = jsonDecode(decrypted) as Map<String, dynamic>;
      final unpacked = RewardPack.fromJson(parsed);

      expect(unpacked.title, equals('Secret Special Pack'));
      expect(unpacked.rewards.first.title, equals('VIP Weekend Pass'));
      expect(unpacked.rewards.first.cost, equals(500));
    });
  });
}
