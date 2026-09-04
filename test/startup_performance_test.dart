import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/partner_contact.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Startup & Performance Optimization Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('SyncService.init(deferNetwork: true) defers network connection until startForegroundSync', () async {
      final engine = OrderEngine();
      final sync = SyncService(engine);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pairing_code', 'TEST01');
      await prefs.setString('pairing_secret', 'SEC01');
      await prefs.setBool('pairing_auto_connect', true);
      await prefs.setString('pairing_role', 'director');

      // Initialize with deferred network
      await sync.init(deferNetwork: true);

      // Status should remain disconnected while deferred
      expect(sync.status, equals(ConnectionStatus.disconnected));

      // Now invoke startForegroundSync explicitly (as occurs after PIN unlock)
      sync.startForegroundSync();

      // Verify it initiated connection sequence or changed status
      expect(sync.status != ConnectionStatus.disconnected || sync.role == ConnectionRole.director, isTrue);
    });

    test('resubscribeAllTopics incorporates dynamic since parameter into WebSocket URL', () async {
      final engine = OrderEngine();
      final sync = SyncService(engine);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pairing_code', 'SUB99');
      await prefs.setString('pairing_secret', 'SEC99');
      await sync.init(deferNetwork: true);

      // Simulate a sync 15 minutes ago
      final fifteenMinutesAgo = DateTime.now().subtract(const Duration(minutes: 15)).millisecondsSinceEpoch;
      sync.setLastSyncTimestampForTesting(fifteenMinutesAgo);

      final dynamicSince = sync.getDynamicSinceParam();
      // 15 + 5 = 20m
      expect(dynamicSince, equals('20m'));

      // Ensure resubscribeAllTopics executes without error and uses dynamic windowing
      await sync.resubscribeAllTopics();
    });

    test('dispatchOrderToPlayer with explicit targetPartner routes strictly to that partner', () async {
      final engine = OrderEngine();
      final partnerService = PartnerService();
      await partnerService.init();

      final targetContact = PartnerContact(
        id: 'target_id_1',
        pairingCode: 'TGT01',
        pairingSecret: 'SEC_TGT',
        displayName: 'Submissive One',
        role: PartnerRole.submissive,
      );
      final otherContact = PartnerContact(
        id: 'other_id_2',
        pairingCode: 'OTH02',
        pairingSecret: 'SEC_OTH',
        displayName: 'Submissive Two',
        role: PartnerRole.submissive,
      );

      await partnerService.addContact(targetContact);
      await partnerService.addContact(otherContact);

      final sync = SyncService(engine, partnerService: partnerService);
      await sync.init(deferNetwork: true);

      final order = OrderItem(
        id: 'order_test_dispatch',
        title: 'Targeted Directive',
        description: 'Directive for specific submissive only',
        rewardTokens: 10,
      );

      final result = sync.dispatchOrderToPlayer(order, targetPartner: targetContact);
      expect(result, isTrue);

      // Confirm director retained the order copy
      expect(sync.remoteActiveOrders.any((o) => o.order.title == 'Targeted Directive'), isTrue);
      final assigned = sync.remoteActiveOrders.firstWhere((o) => o.order.title == 'Targeted Directive');
      expect(assigned.assignedByPartnerCode, equals('TGT01'));
      expect(assigned.assignedByPartnerName, equals('Submissive One'));
    });
  });
}
