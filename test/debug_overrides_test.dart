import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/services/debug_settings.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/quest_service.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/views/contacts/partners_and_chat_view.dart';
import 'package:orders_app/views/player/player_dashboard_view.dart';

/// Clearing a directive without completing or forfeiting it records nothing
/// and tells the director nothing, so those controls are off unless someone
/// has turned them on in the debug panel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late OrderEngine engine;
  late SyncService sync;
  late PartnerService partners;
  late QuestService quests;

  Future<void> harness(WidgetTester tester, Widget view) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: engine),
          ChangeNotifierProvider.value(value: sync),
          ChangeNotifierProvider.value(value: partners),
          ChangeNotifierProvider.value(value: quests),
        ],
        child: MaterialApp(home: view),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DebugSettings.instance.setShowPlayerOverrides(false);
    engine = OrderEngine();
    await engine.init();
    partners = PartnerService();
    await partners.init();
    quests = QuestService();
    await quests.loadFromStorage();
    sync = SyncService(engine, partnerService: partners);
    await sync.init(deferNetwork: true);

    engine.assignOrder(
      OrderItem(id: 'ord_1', title: 'Plank', description: 'Two minutes', rewardTokens: 10),
      id: 'active_1',
    );
  });

  testWidgets('the override controls are hidden by default', (tester) async {
    await harness(tester, const PlayerDashboardView());

    expect(find.byTooltip('Clean / Override Tasks'), findsNothing);
    expect(find.byTooltip('Dismiss / Clear Task'), findsNothing);
  });

  testWidgets('turning them on in the debug panel shows them', (tester) async {
    await DebugSettings.instance.setShowPlayerOverrides(true);
    await harness(tester, const PlayerDashboardView());

    expect(find.byTooltip('Clean / Override Tasks'), findsOneWidget);
    expect(find.byTooltip('Dismiss / Clear Task'), findsOneWidget);
  });

  testWidgets('the setting survives a restart', (tester) async {
    await DebugSettings.instance.setShowPlayerOverrides(true);

    // A fresh read of stored settings, as at app start.
    await DebugSettings.instance.load();
    expect(DebugSettings.instance.showPlayerOverrides, isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(DebugSettings.showPlayerOverridesKey), isTrue);
  });

  testWidgets('contacts is one panel with both tabs', (tester) async {
    await harness(tester, const PartnersAndChatView());

    // The destination is called Contacts; partners and chat are its two tabs.
    expect(find.text('Contacts'), findsOneWidget);
    expect(find.text('Partners'), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
  });
}
