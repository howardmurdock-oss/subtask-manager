import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/services/partner_service.dart';

/// Pairing requests carry a freshly generated shared secret every time, so a
/// handled request identifies one exchange — not the person who sent it.
///
/// Banking the bare sender code meant that once someone's request had been
/// handled even once, every later request from them was dropped in silence and
/// they could never pair again. Refusing a person permanently is what blocking
/// is for, and that is a separate, deliberate decision.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('handling one request does not block the next from the same sender',
      () async {
    final partners = PartnerService();
    await partners.init();

    await partners.markRequestHandled('PC1-CODE', 'secret-from-first-attempt');

    expect(partners.isRequestHandled('PC1-CODE', 'secret-from-first-attempt'),
        isTrue,
        reason: 'the exact exchange is done');
    expect(partners.isRequestHandled('PC1-CODE', 'secret-from-second-attempt'),
        isFalse,
        reason: 'a fresh request from the same sender must still be offered');
  });

  test('a replay of the same request is still suppressed', () async {
    // The reason the ledger exists: the relay can redeliver a message, and the
    // user should not be prompted twice for one request.
    final partners = PartnerService();
    await partners.init();

    await partners.markRequestHandled('PC1-CODE', 'the-same-secret');

    expect(partners.isRequestHandled('PC1-CODE', 'the-same-secret'), isTrue);
  });

  test('code formatting differences do not defeat the match', () async {
    final partners = PartnerService();
    await partners.init();

    await partners.markRequestHandled('pc1-code', 'a-secret');

    expect(partners.isRequestHandled('PC1CODE', 'a-secret'), isTrue);
  });

  test('a request with no secret falls back to the coarse match', () async {
    // Nothing distinguishes one secretless request from another, so treating a
    // repeat as new would prompt endlessly.
    final partners = PartnerService();
    await partners.init();

    await partners.markRequestHandled('LEGACY-CODE');

    expect(partners.isRequestHandled('LEGACY-CODE'), isTrue);
  });

  test('blocking is what actually refuses a sender for good', () async {
    final partners = PartnerService();
    await partners.init();
    await partners.addContact(PartnerContact(
      id: 'pc1',
      displayName: 'PC 1',
      pairingCode: 'PC1CODE',
      pairingSecret: 's',
      role: PartnerRole.dominant,
      isBlocked: true,
    ));

    expect(partners.isSenderBlocked('PC1CODE'), isTrue);
    expect(partners.isRequestHandled('PC1CODE', 'any-new-secret'), isFalse,
        reason: 'handled and blocked are different decisions');
  });
}
