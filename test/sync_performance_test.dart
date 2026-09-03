import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/models/sync_message.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SyncService Performance & Incremental History Windowing Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('getDynamicSinceParam returns 24h on fresh install with no past sync', () async {
      final engine = OrderEngine();
      final sync = SyncService(engine);

      expect(sync.getDynamicSinceParam(), equals('24h'));
    });

    test('getDynamicSinceParam computes tight window for recent sync', () async {
      final engine = OrderEngine();
      final sync = SyncService(engine);

      final now = DateTime.now();
      // Sync was 10 minutes ago
      final tenMinutesAgo = now.subtract(const Duration(minutes: 10)).millisecondsSinceEpoch;
      sync.setLastSyncTimestampForTesting(tenMinutesAgo);

      // Should be 10 + 5 min safety buffer = 15m
      expect(sync.getDynamicSinceParam(), equals('15m'));
    });

    test('getDynamicSinceParam clamps small intervals to minimum 5m', () async {
      final engine = OrderEngine();
      final sync = SyncService(engine);

      final now = DateTime.now();
      // Sync was 30 seconds ago
      final thirtySecondsAgo = now.subtract(const Duration(seconds: 30)).millisecondsSinceEpoch;
      sync.setLastSyncTimestampForTesting(thirtySecondsAgo);

      // Should clamp to 5m minimum
      expect(sync.getDynamicSinceParam(), equals('5m'));
    });

    test('getDynamicSinceParam caps large intervals to 24h maximum', () async {
      final engine = OrderEngine();
      final sync = SyncService(engine);

      final now = DateTime.now();
      // Sync was 3 days ago
      final threeDaysAgo = now.subtract(const Duration(days: 3)).millisecondsSinceEpoch;
      sync.setLastSyncTimestampForTesting(threeDaysAgo);

      expect(sync.getDynamicSinceParam(), equals('24h'));
    });

    test('Debounced saving of processed message IDs coalesces rapid message arrivals', () async {
      final engine = OrderEngine();
      final sync = SyncService(engine);
      await sync.init();

      final prefs = await SharedPreferences.getInstance();

      // Trigger multiple message arrivals rapidly
      for (int i = 0; i < 20; i++) {
        await sync.handleIncomingSyncMessage(SyncMessage(
          id: 'test_msg_burst_$i',
          type: SyncMessageType.ping,
          senderId: 'remote_peer_1',
        ));
      }

      // Immediately after the loop, debounced write should not have completed yet or should coalesce
      // Wait for debounce timer to fire (1s)
      await Future.delayed(const Duration(milliseconds: 1100));

      final savedV2 = prefs.getStringList('processed_sync_message_ids_v2');
      expect(savedV2, isNotNull);
      expect(savedV2!.contains('test_msg_burst_0'), isTrue);
      expect(savedV2.contains('test_msg_burst_19'), isTrue);

      sync.dispose();
    });
  });
}
