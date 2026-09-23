import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:orders_app/core/security/security_service.dart';
import 'package:orders_app/core/theme/theme_provider.dart';
import 'package:orders_app/main.dart';
import 'package:orders_app/views/home_screen.dart';
import 'package:orders_app/services/chat_service.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/quest_service.dart';
import 'package:orders_app/services/storage_service.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/services/update_flow.dart';
import 'package:orders_app/services/update_service.dart';
import 'package:orders_app/services/windows_updater.dart';
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
    // A check made minutes ago, which is the normal state of things: the
    // interval only ever elapses while the app is closed.
    SharedPreferences.setMockInitialValues({
      UpdateService.lastCheckedKey: DateTime.now().toIso8601String(),
    });
    UpdateService.fetch = (_) async => Uint8List.fromList(utf8.encode(manifest()));
  });

  tearDown(() {
    UpdateService.fetch = (_) async => null;
    WindowsUpdater.probeForUnfinishedUpdate = () async => null;
    UpdateFlow.instance.dismiss();
  });

  Future<void> pumpApp(WidgetTester tester, {bool screenOnly = false}) async {
    final sync = SyncService(OrderEngine(storage: StorageService()));
    final partners = PartnerService();
    final chat = ChatService();
    final quests = QuestService();
    sync.attachServices(partners, chat, questService: quests);
    addTearDown(sync.dispose);

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
        // The whole app, or the screen on its own. The app registers a resume
        // handler of its own that re-arms scheduling alarms - not what is
        // under test here, and it leaves timers running behind it.
        child: screenOnly
            ? const MaterialApp(home: HomeScreen())
            : const OrdersApp(),
      ),
    );

    // The checks run after the first frame, each with a preference read and a
    // fetch to get through before they can say anything.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('a newer version is offered on launch, even within the interval',
      (WidgetTester tester) async {
    await pumpApp(tester);

    expect(find.textContaining('Version 9.9.0 is available'), findsOneWidget,
        reason: 'the banner must appear on its own, not only from Settings, and '
            'a check made earlier today must not swallow the launch');
  });

  testWidgets('coming back to the app checks too, which on a phone is the only '
      'thing that happens', (WidgetTester tester) async {
    var manifestFetches = 0;
    UpdateService.fetch = (url) async {
      if (!url.path.endsWith('.sig')) manifestFetches++;
      return Uint8List.fromList(utf8.encode(manifest()));
    };

    await pumpApp(tester, screenOnly: true);
    expect(manifestFetches, 1, reason: 'the launch check');

    // Long enough ago that returning counts as opening it.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(UpdateService.lastCheckedKey,
        DateTime.now().subtract(const Duration(hours: 2)).toIso8601String());

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(manifestFetches, 2, reason: 'a resume after two hours must check');
  });

  testWidgets('a download that never installed is reported, not left silent',
      (WidgetTester tester) async {
    // Two real updates failed exactly here: the files were downloaded, the
    // swap did not happen, and the app came back looking untouched.
    WindowsUpdater.probeForUnfinishedUpdate = () async => r'D:\app\Windows-Portable.update';

    await pumpApp(tester);

    expect(find.textContaining('could not be installed'), findsOneWidget);
    expect(find.text('Delete download'), findsOneWidget);
  });
}
