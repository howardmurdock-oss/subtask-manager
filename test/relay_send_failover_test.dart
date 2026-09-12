import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/sync_service.dart';

/// Publishing a directive used to fail over to a *different* relay host when the
/// primary returned 429 or timed out — and then report success.
///
/// A recipient only subscribes to their own configured host, so a directive
/// republished elsewhere was delivered nowhere while the sender believed it had
/// gone out. That produced dispatches which silently vanished and then worked on
/// the retry a moment later.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<SyncService> director() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pairing_code', 'DIR001');
    await prefs.setString('pairing_secret', 'SECRET');
    await prefs.setString('pairing_custom_relay', 'ntfy.envs.net');

    final engine = OrderEngine();
    await engine.init();
    final partners = PartnerService();
    await partners.init();
    final sync = SyncService(engine, partnerService: partners);
    await sync.init(deferNetwork: true);
    return sync;
  }

  SyncMessage directive() => SyncMessage(
        id: 'msg_dispatch',
        type: SyncMessageType.dispatchOrder,
        senderId: 'director_device',
        payload: const {
          'order': {'id': 'ord_1', 'title': 'A Task', 'description': 'x', 'tier': 1},
          'activeOrderId': 'active_1',
          'senderCode': 'DIR001',
          'senderName': 'Director',
        },
      );

  test('an unreachable relay reports failure rather than phantom success',
      () async {
    // HttpClient in a test binding refuses every request, so all attempts fail.
    final sync = await director();

    final ok = await sync.sendDirectToTopic('TGT01', 'SEC_TGT', directive());

    expect(ok, isFalse,
        reason: 'the caller must be able to tell the directive never left');
  });

  test('a failed send never reaches a host the recipient is not subscribed to',
      () async {
    final sync = await director();

    await sync.sendDirectToTopic('TGT01', 'SEC_TGT', directive());
    final status = await SyncService.lastRelaySendStatus();

    expect(status, contains('FAILED'));
    expect(status, contains('ntfy.envs.net'),
        reason: 'retries stay on the configured host');
    expect(status, isNot(contains('ntfy.sh')),
        reason: 'publishing to another relay delivers the directive nowhere');
  });

  test('no failure is recorded before anything has been sent', () async {
    await director();
    expect(await SyncService.lastRelaySendStatus(),
        equals('No send failures recorded'));
  });
}
