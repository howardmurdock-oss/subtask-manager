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

// A director reaches a partner's toy from the main screen, not the toy
// settings.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  final alex = PartnerContact(
    id: 'p_alex',
    displayName: 'Alex',
    pairingCode: 'ALEX01',
    pairingSecret: 'secret-a',
    role: PartnerRole.submissive,
  );
  final blair = PartnerContact(
    id: 'p_blair',
    displayName: 'Blair',
    pairingCode: 'BLAIR1',
    pairingSecret: 'secret-b',
    role: PartnerRole.submissive,
  );

  Future<(SyncService, Future<void> Function())> pumpDashboard(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final engine = OrderEngine();
    await engine.init();
    final partnerService = PartnerService();
    await partnerService.init();
    final chatService = ChatService();
    await chatService.init();
    final questService = QuestService();
    final scheduleService = ScheduleService();
    await partnerService.addContact(alex);
    await partnerService.addContact(blair);
    await partnerService.setActivePartner(alex.id);
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
        child: const MaterialApp(home: Scaffold(body: DirectorDashboardView())),
      ),
    );
    await tester.pumpAndSettle();

    return (
      sync,
      () async {
        await tester.pump(const Duration(seconds: 10));
        scheduleService.dispose();
        sync.dispose();
        engine.dispose();
      }
    );
  }

  testWidgets('no card until a partner has shared a toy', (tester) async {
    final (_, dispose) = await pumpDashboard(tester);
    expect(find.byKey(const Key('dashboard-partner-toys')), findsNothing);
    await dispose();
  });

  testWidgets("partners' toys on the dashboard: online ones first, with Control", (tester) async {
    final (sync, dispose) = await pumpDashboard(tester);
    sync.debugSetPartnerToy(blair, PartnerToyStatus(online: false, at: DateTime.now()));
    sync.debugSetPartnerToy(alex, PartnerToyStatus(online: true, toyName: 'Lush', at: DateTime.now()));
    await tester.pumpAndSettle();

    final card = find.byKey(const Key('dashboard-partner-toys'));
    await tester.scrollUntilVisible(card, 200, scrollable: find.byType(Scrollable).first);
    expect(find.descendant(of: card, matching: find.text('Lush')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('Toy not connected right now')), findsOneWidget);
    expect(tester.getTopLeft(find.descendant(of: card, matching: find.text('Alex'))).dy,
        lessThan(tester.getTopLeft(find.descendant(of: card, matching: find.text('Blair'))).dy));
    expect(find.byKey(const Key('dashboard-toy-BLAIR1')), findsNothing, reason: 'nothing to control yet');

    final control = find.byKey(const Key('dashboard-toy-ALEX01'));
    expect(tester.getRect(control).right, lessThanOrEqualTo(360));
    expect(tester.takeException(), isNull);

    await dispose();
  });
}
