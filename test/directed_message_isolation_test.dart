import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/order_pack.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/models/quest_item.dart';
import 'package:orders_app/services/chat_service.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/quest_service.dart';
import 'package:orders_app/services/sync_service.dart';

/// Regression coverage for directed messages leaking to the whole contact list.
///
/// Every device subscribes to its own relay topic *and* every contact's topic,
/// so that contacts can see each other's state broadcasts. That makes a topic a
/// shared channel, not a private one. Directed traffic published there was
/// readable — and mountable — by every contact of the sender: a directive sent
/// by user 1 to user 2 also landed on user 3's dashboard.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const myCode = 'MINE01';
  const targetCode = 'TGT01';
  const otherCode = 'OTH02';

  PartnerContact contact(String id, String code, String secret, PartnerRole role) =>
      PartnerContact(
        id: id,
        pairingCode: code,
        pairingSecret: secret,
        displayName: 'Partner $code',
        role: role,
      );

  OrderItem order(String id, String title) => OrderItem(
        id: id,
        title: title,
        description: 'Directive body',
        tier: 1,
        rewardTokens: 10,
      );

  /// A director with two submissive contacts, both of whose topics it is
  /// subscribed to.
  Future<(SyncService, PartnerService, OrderEngine)> directorWithTwoContacts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pairing_code', myCode);
    await prefs.setString('pairing_secret', 'MY_SECRET');

    final engine = OrderEngine();
    await engine.init();
    final partners = PartnerService();
    await partners.init();
    await partners.addContact(
        contact('target_id', targetCode, 'SEC_TGT', PartnerRole.submissive));
    await partners.addContact(
        contact('other_id', otherCode, 'SEC_OTH', PartnerRole.submissive));

    final sync = SyncService(engine, partnerService: partners);
    await sync.init(deferNetwork: true);
    sync.debugSentToCodes.clear();
    return (sync, partners, engine);
  }

  group('Directed sends reach only their target', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('dispatching an order to one partner does not publish to our own topic',
        () async {
      final (sync, partners, _) = await directorWithTwoContacts();
      final target = partners.contacts.firstWhere((c) => c.pairingCode == targetCode);

      sync.dispatchOrderToPlayer(order('ord_1', 'Targeted Directive'),
          targetPartner: target);

      // Exactly one recipient. Previously this also published to MINE01, which
      // every contact subscribes to, so OTH02 received the directive too.
      expect(sync.debugSentToCodes, equals([targetCode]));
      expect(sync.debugSentToCodes.any((c) => c.startsWith('SELF:')), isFalse,
          reason: 'a directed dispatch must never hit our own broadcast topic');
      expect(sync.debugSentToCodes, isNot(contains(otherCode)));
    });

    test('dispatching a quest to one partner does not fan out', () async {
      final (sync, partners, _) = await directorWithTwoContacts();
      sync.attachServices(partners, ChatService(), questService: QuestService());
      final target = partners.contacts.firstWhere((c) => c.pairingCode == targetCode);

      sync.dispatchQuestToPlayer(
        Quest(id: 'q1', title: 'A Quest', description: 'Do things'),
        targetPartner: target,
      );

      expect(sync.debugSentToCodes, equals([targetCode]));
    });

    test('sending a pack to one partner does not fan out', () async {
      final (sync, partners, _) = await directorWithTwoContacts();
      final target = partners.contacts.firstWhere((c) => c.pairingCode == targetCode);

      sync.sendPackToPlayer(
        OrderPack(
          id: 'p1',
          title: 'A Pack',
          description: 'Pack body',
          author: 'Director',
          orders: [order('ord_p', 'Packed Task')],
        ),
        targetPartner: target,
      );

      expect(sync.debugSentToCodes, equals([targetCode]));
    });

    test('adjusting one partner tokens does not fan out', () async {
      final (sync, partners, _) = await directorWithTwoContacts();
      final target = partners.contacts.firstWhere((c) => c.pairingCode == targetCode);

      sync.adjustPlayerTokens(-5, 'Penalty', targetPartner: target);

      expect(sync.debugSentToCodes, equals([targetCode]));
    });

    test('a pack with no addressable recipient is published addressed, not broadcast',
        () async {
      // With no target and no active partner there is nobody to name, and the
      // legacy behaviour published an *unaddressed* message on our own topic —
      // which every contact then accepted as if it were meant for them.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pairing_code', myCode);
      await prefs.setString('pairing_secret', 'MY_SECRET');
      final engine = OrderEngine();
      await engine.init();
      final partners = PartnerService();
      await partners.init();
      final sync = SyncService(engine, partnerService: partners);
      await sync.init(deferNetwork: true);
      sync.debugSentToCodes.clear();

      sync.sendPackToPlayer(OrderPack(
        id: 'p2',
        title: 'Orphan Pack',
        description: 'No recipient',
        author: 'Director',
        orders: [order('ord_o', 'Orphan Task')],
      ));

      expect(sync.debugSentToCodes, equals([myCode]),
          reason: 'must be addressed to our own code, not published untargeted');
      expect(sync.debugSentToCodes.any((c) => c.startsWith('SELF:')), isFalse);
    });

    test('a token adjustment with no addressable recipient is published addressed',
        () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pairing_code', myCode);
      await prefs.setString('pairing_secret', 'MY_SECRET');
      final engine = OrderEngine();
      await engine.init();
      final partners = PartnerService();
      await partners.init();
      final sync = SyncService(engine, partnerService: partners);
      await sync.init(deferNetwork: true);
      sync.debugSentToCodes.clear();

      sync.adjustPlayerTokens(10, 'Bonus');

      expect(sync.debugSentToCodes, equals([myCode]));
      expect(sync.debugSentToCodes.any((c) => c.startsWith('SELF:')), isFalse);
    });

    test('state broadcasts are no longer published on our own topic', () async {
      // Every contact reads our own topic. State used to be published there,
      // which handed each contact the whole dashboard - every director's
      // tasks and the notes submitted as proof. It now goes directly to each
      // director, holding only their own directives (multi_partner_routing_test).
      final (sync, _, _) = await directorWithTwoContacts();

      sync.broadcastPlayerState();
      await Future.delayed(const Duration(milliseconds: 20));

      expect(sync.debugSentToCodes.any((c) => c.startsWith('SELF:')), isFalse);
    });
  });

  group('Receivers drop what was not addressed to them', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<(SyncService, OrderEngine)> receiver({List<String>? pastCodes}) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pairing_code', myCode);
      await prefs.setString('pairing_secret', 'MY_SECRET');
      if (pastCodes != null) {
        await prefs.setStringList('past_pairing_codes_v1', pastCodes);
      }
      final engine = OrderEngine();
      await engine.init();
      final partners = PartnerService();
      await partners.init();
      final sync = SyncService(engine, partnerService: partners);
      await sync.init(deferNetwork: true);
      return (sync, engine);
    }

    SyncMessage dispatchTo(String? code, {String id = 'msg_1'}) => SyncMessage(
          id: id,
          type: SyncMessageType.dispatchOrder,
          senderId: 'director_device',
          targetCode: code,
          payload: {
            'order': order('ord_leak', 'Someone Elses Directive').toJson(),
            'activeOrderId': 'active_$id',
            'senderCode': 'DIR99',
            'senderName': 'Director',
          },
        );

    test('an order addressed to another partner is ignored', () async {
      final (sync, engine) = await receiver();

      await sync.handleIncomingSyncMessage(dispatchTo(otherCode));

      expect(engine.activeOrders, isEmpty,
          reason: 'this directive was addressed to $otherCode, not us');
    });

    test('an order addressed to us is accepted', () async {
      final (sync, engine) = await receiver();

      await sync.handleIncomingSyncMessage(dispatchTo(myCode));

      expect(engine.activeOrders.length, 1);
      expect(engine.activeOrders.first.order.title, 'Someone Elses Directive');
    });

    test('an unaddressed order from an older build is still accepted', () async {
      // Backward compatibility: a v1.1.1 sender sets no target, and dropping
      // those would break dispatch to anyone who has not updated yet.
      final (sync, engine) = await receiver();

      await sync.handleIncomingSyncMessage(dispatchTo(null));

      expect(engine.activeOrders.length, 1);
    });

    test('an order addressed to a code we have migrated away from is accepted',
        () async {
      final (sync, engine) = await receiver(pastCodes: ['OLDME9']);

      await sync.handleIncomingSyncMessage(dispatchTo('OLDME9'));

      expect(engine.activeOrders.length, 1,
          reason: 'a code we used to own is still legitimately ours');
    });

    test('addressing tolerates formatting differences in the code', () async {
      final (sync, engine) = await receiver();

      await sync.handleIncomingSyncMessage(dispatchTo(' mine-01 '));

      expect(engine.activeOrders.length, 1);
    });
  });

  group('SyncMessage addressing', () {
    test('targetCode survives a JSON round-trip', () {
      final msg = SyncMessage(
        type: SyncMessageType.dispatchOrder,
        senderId: 'device_a',
        targetCode: targetCode,
      );
      final decoded = SyncMessage.decode(msg.encode());
      expect(decoded.targetCode, targetCode);
    });

    test('withTargetCode preserves every other field', () {
      final original = SyncMessage(
        id: 'm1',
        type: SyncMessageType.dispatchQuest,
        senderId: 'device_a',
        targetId: 'contact_uuid',
        payload: const {'k': 'v'},
      );
      final addressed = original.withTargetCode(targetCode);

      expect(addressed.targetCode, targetCode);
      expect(addressed.id, original.id);
      expect(addressed.type, original.type);
      expect(addressed.senderId, original.senderId);
      expect(addressed.targetId, original.targetId);
      expect(addressed.timestamp, original.timestamp);
      expect(addressed.payload, original.payload);
    });

    test('a message decoded from an older build has no target', () {
      final legacy = '{"id":"m9","type":"dispatchOrder","senderId":"d",'
          '"timestamp":"2026-01-01T00:00:00.000","payload":{}}';
      expect(SyncMessage.decode(legacy).targetCode, isNull);
    });
  });
}
