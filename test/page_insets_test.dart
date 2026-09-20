import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/services/chat_service.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/views/contacts/partner_directory_view.dart';
import 'package:orders_app/views/messenger/messenger_inbox_view.dart';
import 'package:orders_app/views/player/stats_view.dart';
import 'package:orders_app/services/sync_service.dart';

/// Pages opened on their own have nothing reserving the space the app's bottom
/// navigation bar used to occupy, so their lists run underneath the system
/// navigation bar - and the last entry can never be scrolled into view. Stats
/// hit this the moment it moved out of the bar and into Settings.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const systemBar = 48.0;

  late OrderEngine engine;
  late PartnerService partners;
  late SyncService sync;
  late ChatService chat;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    engine = OrderEngine();
    await engine.init();
    partners = PartnerService();
    await partners.init();
    chat = ChatService();
    sync = SyncService(engine, partnerService: partners);
    await sync.init(deferNetwork: true);
    engine.assignOrder(
      OrderItem(id: 'ord_1', title: 'Plank', description: 'Two minutes', rewardTokens: 10),
      id: 'active_1',
    );
  });

  Future<void> pumpAsOwnPage(WidgetTester tester, Widget view) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: engine),
          ChangeNotifierProvider.value(value: partners),
          ChangeNotifierProvider.value(value: sync),
          ChangeNotifierProvider.value(value: chat),
        ],
        child: MaterialApp(
          home: MediaQuery(
            // A phone with a gesture bar, and no bottom navigation bar to
            // absorb it.
            data: const MediaQueryData(padding: EdgeInsets.only(bottom: systemBar)),
            child: view,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  double bottomPaddingOf(WidgetTester tester) {
    final list = tester.widgetList<ListView>(find.byType(ListView)).first;
    return (list.padding as EdgeInsets?)?.bottom ?? 0;
  }

  testWidgets('the stats history clears the system navigation bar', (tester) async {
    await pumpAsOwnPage(tester, const StatsView());
    expect(bottomPaddingOf(tester), greaterThanOrEqualTo(systemBar));
  });

  testWidgets('the partner directory clears it too', (tester) async {
    await pumpAsOwnPage(tester, const PartnerDirectoryView());
    expect(bottomPaddingOf(tester), greaterThanOrEqualTo(systemBar));
  });

  testWidgets('so does the conversation list', (tester) async {
    await partners.addContact(PartnerContact(
      id: 'p1',
      displayName: 'Partner',
      pairingCode: 'CODE1',
      pairingSecret: 'SECRET',
    ));
    await pumpAsOwnPage(tester, const MessengerInboxView());
    expect(bottomPaddingOf(tester), greaterThanOrEqualTo(systemBar));
  });
}
