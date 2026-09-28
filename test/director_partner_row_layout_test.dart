import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/services/chat_service.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/quest_service.dart';
import 'package:orders_app/services/schedule_service.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/views/director/director_dashboard_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // The Active Submissive row on an Android phone: the partner dropdown sized
  // itself to its widest item, "Myself (This Device)", whichever partner was
  // selected, and pushed the Chat button past the right edge of the screen.
  /// Returns what stops the services' timers. It has to run inside the test
  /// body: the check for pending timers comes before tear-downs do.
  Future<Future<void> Function()> pumpDashboardOnPhone(
    WidgetTester tester, {
    required String partnerName,
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final engine = OrderEngine();
    await engine.init();
    final partnerService = PartnerService();
    await partnerService.init();
    final chatService = ChatService();
    await chatService.init();
    final questService = QuestService();
    final scheduleService = ScheduleService();
    final submissive = PartnerContact(
      id: 'sub_1',
      displayName: partnerName,
      pairingCode: 'SUB123',
      pairingSecret: 'sec123',
      role: PartnerRole.submissive,
    );
    await partnerService.addContact(submissive);
    await partnerService.setActivePartner(submissive.id);
    final sync = SyncService(engine, partnerService: partnerService);
    await sync.init();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: engine),
          ChangeNotifierProvider.value(value: sync),
          ChangeNotifierProvider.value(value: partnerService),
          ChangeNotifierProvider.value(value: chatService),
          ChangeNotifierProvider.value(value: questService),
          ChangeNotifierProvider.value(value: scheduleService),
        ],
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(360, 800),
              textScaler: TextScaler.linear(textScale),
            ),
            child: const Scaffold(body: DirectorDashboardView()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    return () async {
      // SyncService.init starts a one-off timer, which starts the relay
      // connection and its own 8s timeout; dispose cancels neither.
      await tester.pump(const Duration(seconds: 10));
      scheduleService.dispose();
      sync.dispose();
      engine.dispose();
    };
  }

  void expectChatButtonOnScreen(WidgetTester tester) {
    final chat = find.text('Chat');
    expect(chat, findsOneWidget);
    final rect = tester.getRect(chat);
    expect(rect.right, lessThanOrEqualTo(360),
        reason: 'the Chat button must be inside the screen, not past its edge');
  }

  testWidgets('the Chat button stays on screen at phone width', (tester) async {
    final dispose = await pumpDashboardOnPhone(tester, partnerName: 'PC 1');
    expectChatButtonOnScreen(tester);
    await dispose();
  });

  testWidgets('with large text, the Chat button stays on screen', (tester) async {
    final dispose = await pumpDashboardOnPhone(tester, partnerName: 'PC 1', textScale: 1.3);
    expectChatButtonOnScreen(tester);
    await dispose();
  });

  testWidgets('a long partner name is shortened, not pushed off screen', (tester) async {
    final dispose = await pumpDashboardOnPhone(
      tester,
      partnerName: 'A Partner With A Remarkably Long Display Name',
    );
    expectChatButtonOnScreen(tester);
    await dispose();
  });
}
