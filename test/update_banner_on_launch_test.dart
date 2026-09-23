import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:orders_app/core/security/security_service.dart';
import 'package:orders_app/core/theme/theme_provider.dart';
import 'package:orders_app/main.dart';
import 'package:orders_app/services/chat_service.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/quest_service.dart';
import 'package:orders_app/services/storage_service.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/services/update_flow.dart';
import 'package:orders_app/services/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The update banner is the only thing that tells a sideloaded build a newer
/// one exists. The check behind it was written, tested and then never called
/// from anywhere - so no one ever saw the banner, and the only way to find an
/// update was to go looking for it in Settings.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String manifest() => jsonEncode({
        'version': '9.9.0',
        'released': '2099-01-01',
        'notesUrl': 'https://github.com/howardmurdock-oss/subtask-manager/releases/tag/v9.9.0',
        'downloads': {
          for (final platform in ['windows', 'android', 'macos', 'linux'])
            platform: {
              'url': 'https://github.com/howardmurdock-oss/subtask-manager/'
                  'releases/latest/download/subTaskManager-Release.zip',
              'sha256': 'a' * 64,
              'size': 15608749,
            },
        },
      });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UpdateService.fetch = (_) async => Uint8List.fromList(utf8.encode(manifest()));
  });

  tearDown(() {
    UpdateService.fetch = (_) async => null;
    UpdateFlow.instance.dismiss();
  });

  testWidgets('a newer version is offered on launch, without being asked',
      (WidgetTester tester) async {
    final sync = SyncService(OrderEngine(storage: StorageService()));
    final partners = PartnerService();
    final chat = ChatService();
    final quests = QuestService();
    sync.attachServices(partners, chat, questService: quests);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: ThemeProvider()),
          ChangeNotifierProvider.value(value: SecurityService()),
          ChangeNotifierProvider.value(value: OrderEngine(storage: StorageService())),
          ChangeNotifierProvider.value(value: partners),
          ChangeNotifierProvider.value(value: chat),
          ChangeNotifierProvider.value(value: quests),
          ChangeNotifierProvider.value(value: sync),
        ],
        child: const OrdersApp(),
      ),
    );

    // The check runs after the first frame and has a preference read and a
    // fetch to get through before it can say anything.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.textContaining('Version 9.9.0 is available'), findsOneWidget,
        reason: 'the banner must appear on its own, not only from Settings');

    sync.dispose();
  });
}
