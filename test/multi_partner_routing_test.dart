import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/active_order.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/sync_service.dart';

/// Routing with more than one partner.
///
/// Every one of these reached, or acted on, the wrong person before: a
/// director's device lost track of which player held a directive as soon as
/// that player synced, and fell back to "the selected partner and every other
/// player"; receivers matched tasks by title, so an update about one player's
/// "Plank" landed on every "Plank".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const directorCode = 'DIR001';
  const otherDirectorCode = 'DIR002';
  const p1Code = 'PLAY01';
  const p2Code = 'PLAY02';

  PartnerContact contact(String id, String code, PartnerRole role) => PartnerContact(
        id: id,
        pairingCode: code,
        pairingSecret: 'SEC_$code',
        displayName: 'Partner $code',
        role: role,
      );

  OrderItem plank() => OrderItem(
        id: 'tpl_plank',
        title: 'Plank',
        description: 'Two minutes',
        tier: 1,
        rewardTokens: 10,
      );

  Future<void> settle() => Future.delayed(const Duration(milliseconds: 30));

  Future<(SyncService, PartnerService, OrderEngine)> device(
      String myCode, List<PartnerContact> contacts) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pairing_code', myCode);
    await prefs.setString('pairing_secret', 'MY_SECRET');
    final engine = OrderEngine();
    await engine.init();
    final partners = PartnerService();
    await partners.init();
    for (final c in contacts) {
      await partners.addContact(c);
    }
    final sync = SyncService(engine, partnerService: partners);
    await sync.init(deferNetwork: true);
    sync.debugSentToCodes.clear();
    sync.debugSentMessages.clear();
    return (sync, partners, engine);
  }

  Future<(SyncService, PartnerService, OrderEngine)> director() => device(directorCode, [
        contact('p1', p1Code, PartnerRole.submissive),
        contact('p2', p2Code, PartnerRole.submissive),
      ]);

  PartnerContact find(PartnerService ps, String code) =>
      ps.contacts.firstWhere((c) => c.pairingCode == code);

  /// The player's copy of a directive, as it comes back in their state: it
  /// names the director as the assigner, not the player as the holder.
  Map<String, dynamic> playerCopy(ActiveOrder dispatched, {OrderStatus? status}) => ActiveOrder(
        id: dispatched.id,
        order: dispatched.order,
        status: status ?? OrderStatus.active,
        assignedByDirector: true,
        assignedByPartnerCode: directorCode,
        assignedByPartnerId: 'director_device',
        assignedByPartnerName: 'Director',
      ).toJson();

  SyncMessage stateFrom(String code, {List<Map<String, dynamic>> active = const [],
          List<Map<String, dynamic>> review = const []}) =>
      SyncMessage(
        type: SyncMessageType.sendState,
        senderId: 'device_$code',
        payload: {
          'senderCode': code,
          'tokens': 5,
          'streak': 1,
          'activeOrders': active,
          'underReviewOrders': review,
        },
      );

  ActiveOrder dispatchedTo(SyncService sync, String code) =>
      sync.remoteActiveOrders.firstWhere((o) => o.heldByCode == code);

  group('director side', () {
    test('a resend reaches only the player holding the directive', () async {
      final (sync, partners, _) = await director();
      sync.dispatchOrderToPlayer(plank(), targetPartner: find(partners, p1Code));
      await settle();
      sync.debugSentToCodes.clear();

      await sync.resendDispatchedOrder(dispatchedTo(sync, p1Code));
      await settle();

      expect(sync.debugSentToCodes, contains(p1Code));
      expect(sync.debugSentToCodes, isNot(contains(p2Code)),
          reason: 'resends used to go to every player, flagged to skip their duplicate checks');
    });

    test('the holder survives the player syncing its own copy back', () async {
      final (sync, partners, _) = await director();
      sync.dispatchOrderToPlayer(plank(), targetPartner: find(partners, p1Code));
      await settle();
      final dispatched = dispatchedTo(sync, p1Code);

      await sync.handleIncomingSyncMessage(stateFrom(p1Code, active: [playerCopy(dispatched)]));
      sync.debugSentToCodes.clear();

      // The synced copy names the director as assigner; the holder must remain.
      final synced = sync.remoteActiveOrders.firstWhere((o) => o.id == dispatched.id);
      expect(synced.heldByCode, p1Code);

      sync.recallDispatchedOrder(synced.id, orderId: synced.order.id, orderTitle: synced.order.title);
      await settle();
      expect(sync.debugSentToCodes, contains(p1Code));
      expect(sync.debugSentToCodes, isNot(contains(p2Code)));
    });

    test("one player's state does not clear another player's directives", () async {
      final (sync, partners, _) = await director();
      sync.dispatchOrderToPlayer(plank(), targetPartner: find(partners, p1Code));
      sync.dispatchOrderToPlayer(plank(), targetPartner: find(partners, p2Code));
      await settle();
      final toP1 = dispatchedTo(sync, p1Code);
      final toP2 = dispatchedTo(sync, p2Code);

      await sync.handleIncomingSyncMessage(stateFrom(p1Code, active: [playerCopy(toP1)]));
      await sync.handleIncomingSyncMessage(stateFrom(p2Code, active: [playerCopy(toP2)]));
      // Player 2 reports again; player 1's directive is, naturally, absent.
      await sync.handleIncomingSyncMessage(stateFrom(p2Code, active: [playerCopy(toP2)]));

      final p1Card = sync.remoteActiveOrders.firstWhere((o) => o.id == toP1.id);
      expect(p1Card.status, OrderStatus.active,
          reason: 'was marked "Emergency Cleared by Submissive" whenever the other player synced');
      expect(sync.remoteActiveOrders.where((o) => o.id == toP2.id), hasLength(1));
    });

    test("one player's review list does not replace another's", () async {
      final (sync, partners, _) = await director();
      sync.dispatchOrderToPlayer(plank(), targetPartner: find(partners, p1Code));
      sync.dispatchOrderToPlayer(plank(), targetPartner: find(partners, p2Code));
      await settle();
      final toP1 = dispatchedTo(sync, p1Code);
      final toP2 = dispatchedTo(sync, p2Code);

      await sync.handleIncomingSyncMessage(
          stateFrom(p1Code, review: [playerCopy(toP1, status: OrderStatus.underReview)]));
      await sync.handleIncomingSyncMessage(
          stateFrom(p2Code, review: [playerCopy(toP2, status: OrderStatus.underReview)]));

      expect(sync.remoteReviewOrders.map((o) => o.id), containsAll([toP1.id, toP2.id]));
    });

    test('an approval goes to the player holding it, not to every player', () async {
      final (sync, partners, _) = await director();
      sync.dispatchOrderToPlayer(plank(), targetPartner: find(partners, p1Code));
      await settle();
      final toP1 = dispatchedTo(sync, p1Code);
      // Under review via state sync alone, so no proof-sender was tracked.
      await sync.handleIncomingSyncMessage(
          stateFrom(p1Code, review: [playerCopy(toP1, status: OrderStatus.underReview)]));
      sync.debugSentToCodes.clear();

      sync.approvePlayerProof(toP1.id);
      await settle();

      expect(sync.debugSentToCodes, contains(p1Code));
      expect(sync.debugSentToCodes, isNot(contains(p2Code)));
    });

    test("a status update only touches the sender's directive", () async {
      final (sync, partners, _) = await director();
      sync.dispatchOrderToPlayer(plank(), targetPartner: find(partners, p1Code));
      sync.dispatchOrderToPlayer(plank(), targetPartner: find(partners, p2Code));
      await settle();
      final toP1 = dispatchedTo(sync, p1Code);
      final toP2 = dispatchedTo(sync, p2Code);

      await sync.handleIncomingSyncMessage(SyncMessage(
        type: SyncMessageType.orderStatusUpdate,
        senderId: 'device_$p2Code',
        payload: {
          'activeOrderId': toP2.id,
          'orderTitle': 'Plank',
          'status': 'failed',
          'senderCode': p2Code,
        },
      ));

      expect(sync.remoteActiveOrders.firstWhere((o) => o.id == toP1.id).status, OrderStatus.active);
      expect(sync.remoteActiveOrders.firstWhere((o) => o.id == toP2.id).status, OrderStatus.failed);
    });
  });

  group('player side', () {
    Future<(SyncService, PartnerService, OrderEngine)> player() => device(p1Code, [
          contact('d1', directorCode, PartnerRole.dominant),
          contact('d2', otherDirectorCode, PartnerRole.dominant),
        ]);

    void mount(OrderEngine engine, String id, {String? byCode}) => engine.assignOrder(
          plank(),
          id: id,
          assignedByDirector: byCode != null,
          assignedByPartnerCode: byCode,
          assignedByPartnerName: byCode,
        );

    test('a recall removes the recalled dispatch and nothing else', () async {
      final (sync, _, engine) = await player();
      mount(engine, 'from_d1', byCode: directorCode);
      mount(engine, 'from_d2', byCode: otherDirectorCode);
      mount(engine, 'self_drawn');

      await sync.handleIncomingSyncMessage(SyncMessage(
        type: SyncMessageType.orderStatusUpdate,
        senderId: 'director_device',
        targetCode: p1Code,
        payload: {
          'activeOrderId': 'from_d1',
          'orderId': 'tpl_plank',
          'orderTitle': 'Plank',
          'status': 'recalled',
          'senderCode': directorCode,
        },
      ));

      expect(engine.activeOrders.map((o) => o.id), unorderedEquals(['from_d2', 'self_drawn']),
          reason: 'every "Plank" used to be removed, whoever had set it');
    });

    test("each director is sent only their own directives, and no proof notes of others'", () async {
      final (sync, _, engine) = await player();
      mount(engine, 'from_d1', byCode: directorCode);
      mount(engine, 'from_d2', byCode: otherDirectorCode);
      mount(engine, 'self_drawn');
      sync.debugSentMessages.clear();

      sync.broadcastPlayerState();
      await settle();

      List<String> sentTo(String code) => sync.debugSentMessages
          .where((m) => m.type == SyncMessageType.sendState && m.targetCode == code)
          .expand((m) => (m.payload['activeOrders'] as List).map((o) => (o as Map)['id'] as String))
          .toList();

      expect(sentTo(directorCode), ['from_d1']);
      expect(sentTo(otherDirectorCode), ['from_d2']);
      expect(sync.debugSentToCodes.any((c) => c.startsWith('SELF:')), isFalse);
    });

    test('a forfeit is reported to the assigning director only', () async {
      final (sync, _, engine) = await player();
      mount(engine, 'from_d1', byCode: directorCode);
      sync.debugSentToCodes.clear();

      await sync.notifyOrderFailed(engine.activeOrders.single, reason: 'Voluntarily forfeited');

      expect(sync.debugSentToCodes, [directorCode]);
    });

    test('proof with no known reviewer is not sent to anyone', () async {
      final (sync, _, _) = await player();
      final orphan = ActiveOrder(
        id: 'orphan',
        order: plank(),
        status: OrderStatus.underReview,
        assignedByDirector: true,
      );

      final sent = await sync.sendProofForReview(orphan);

      expect(sent, isFalse);
      expect(sync.debugSentToCodes, isEmpty,
          reason: 'used to fall back to the selected partner, then every director');
    });
  });
}
