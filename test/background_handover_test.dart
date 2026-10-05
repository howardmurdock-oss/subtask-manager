import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/services/background_link_service.dart';

/// Messages that reach the background isolate (the app asleep, as in
/// battery saver) and that it has no handler for must reach the app, not
/// vanish: they used to be dropped here after their id had been marked
/// processed, so the push copy was skipped too.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<List<String>> handedOver() async {
    // The queue is written on a chained future.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return (prefs.getStringList('pending_background_messages_v1') ?? const [])
        .map((raw) => (jsonDecode(raw) as Map)['type'] as String)
        .toList();
  }

  SyncMessage msg(SyncMessageType type) =>
      SyncMessage(type: type, senderId: 'partner-device', payload: {'senderCode': 'SIR123'});

  test('message types the background has no handler for are handed to the app', () async {
    final handler = DirectiveSyncTaskHandler();
    handler.handleBackgroundMessageForTest(msg(SyncMessageType.featureHello));
    handler.handleBackgroundMessageForTest(msg(SyncMessageType.partnerProfile));

    expect(await handedOver(), ['featureHello', 'partnerProfile']);
  });

  test('liveness and state chatter is not kept for later', () async {
    final handler = DirectiveSyncTaskHandler();
    for (final type in [SyncMessageType.ping, SyncMessageType.pong, SyncMessageType.requestState, SyncMessageType.sendState]) {
      handler.handleBackgroundMessageForTest(msg(type));
    }
    expect(await handedOver(), isEmpty);
  });
}
