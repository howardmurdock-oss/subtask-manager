import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/chastity_timer.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/services/chastity_timer_service.dart';
import 'package:orders_app/services/chat_service.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/quest_service.dart';
import 'package:orders_app/services/storage_service.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/views/chastity_timer/timer_dashboard_card.dart';
import 'package:orders_app/views/chastity_timer/timer_detail_view.dart';
import 'package:orders_app/views/chastity_timer/timer_setup_view.dart';

/// What each side sees and can do on the timer screens.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late OrderEngine engine;
  late PartnerService partners;
  late SyncService sync;
  late ChastityTimerService timers;

  final now = DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> view({required String role, bool hidden = false, bool over = false, String? digits}) => {
        'id': 't1',
        'role': role,
        'manager': role == 'director',
        'status': over ? 'ended' : 'running',
        'startAt': now,
        'endAt': hidden && role == 'player' && !over ? null : now + (over ? -1000 : 3 * 3600 * 1000),
        'config': {
          'baseSeconds': hidden && role == 'player' ? null : 3 * 3600,
          'hidden': hidden,
          'director': {'canAdd': true, 'canRemove': true, 'dailyCapSeconds': null},
          'public': {'enabled': false},
          'combination': {'enabled': true, 'length': 4, 'digits': digits},
        },
        'history': [
          {'id': 'd1', 'at': now, 'actor': 'director', 'delta': hidden && role == 'player' ? null : 600},
        ],
        'publicId': null,
        'now': now,
      };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    engine = OrderEngine(storage: StorageService());
    await engine.init();
    partners = PartnerService();
    await partners.init();
    final chat = ChatService();
    await chat.init();
    sync = SyncService(engine);
    sync.attachServices(partners, chat, questService: QuestService());
    timers = ChastityTimerService();
    sync.attachTimerService(timers);
  });

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: engine),
        ChangeNotifierProvider.value(value: partners),
        ChangeNotifierProvider.value(value: sync),
        ChangeNotifierProvider.value(value: timers),
      ],
      child: MaterialApp(home: child),
    ));
    await tester.pump();
  }

  /// Lets the screens' one-second ticks and the sync timers run out before
  /// the test ends.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  }

  testWidgets('a hidden timer shows the player no time, but always the emergency release', (tester) async {
    ChastityTimerService.request = (m, u, {key, body}) async => TimerApiResponse(200, view(role: 'player', hidden: true));
    await timers.addShared(id: 't1', role: TimerRole.player, key: 'P', partnerName: 'Tessa');

    await pump(tester, const TimerDetailView(timerId: 't1'));

    expect(find.text('??:??:??'), findsOneWidget);
    expect(find.text('The time left is hidden'), findsOneWidget);
    expect(find.text('Emergency release'), findsOneWidget);
    expect(find.text('REMOVE TIME'), findsNothing, reason: 'a player can only add');
    expect(find.text('changed'), findsOneWidget, reason: 'the amount of a change is hidden too');
    expect(find.textContaining('Revealed when the timer ends'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('the director can add and remove, and sees the combination', (tester) async {
    ChastityTimerService.request =
        (m, u, {key, body}) async => TimerApiResponse(200, view(role: 'director', digits: '4821'));
    await timers.addShared(id: 't1', role: TimerRole.director, key: 'D', partnerName: 'PC 1');

    await pump(tester, const TimerDetailView(timerId: 't1'));

    expect(find.text('ADD TIME'), findsOneWidget);
    expect(find.text('REMOVE TIME'), findsOneWidget);
    expect(find.text('4 8 2 1'), findsOneWidget);
    expect(find.text('End the timer now'), findsOneWidget);
    expect(find.text('+10 minutes'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a finished timer shows the player the combination', (tester) async {
    ChastityTimerService.request =
        (m, u, {key, body}) async => TimerApiResponse(200, view(role: 'player', over: true, digits: '4821'));
    await timers.addShared(id: 't1', role: TimerRole.player, key: 'P');

    await pump(tester, const TimerDetailView(timerId: 't1'));

    expect(find.text('Unlocked'), findsOneWidget);
    expect(find.text('4 8 2 1'), findsOneWidget);
    expect(find.text('Emergency release'), findsNothing);
    await finish(tester);
  });

  testWidgets('a partner without the timer cannot be picked, and is told why', (tester) async {
    final withIt = PartnerContact(
        id: 'a', displayName: 'Has It', pairingCode: 'HAS111', pairingSecret: 's', role: PartnerRole.submissive);
    final without = PartnerContact(
        id: 'b', displayName: 'PC 1', pairingCode: 'OLD222', pairingSecret: 's', role: PartnerRole.submissive);
    await partners.addContact(withIt);
    await partners.addContact(without);
    await sync.handleIncomingSyncMessage(SyncMessage(
      type: SyncMessageType.featureHello,
      senderId: 'x',
      payload: {'senderCode': 'HAS111', 'features': ['chastityTimer']},
    ));

    await pump(tester, const TimerSetupView(role: TimerRole.director));

    expect(find.textContaining("PC 1 can't use the Chastity Timer yet"), findsOneWidget);
    expect(find.textContaining('Patreon build'), findsOneWidget);
    expect(find.textContaining('Will get their key'), findsOneWidget);
    final tile = tester.widget<RadioListTile<String?>>(find.widgetWithText(RadioListTile<String?>, 'PC 1'));
    expect(tile.enabled, isFalse);
    await finish(tester);
  });

  testWidgets("a contact is listed whatever role it was saved with, not hidden as 'nobody paired'",
      (tester) async {
    // The case that was reported: a director whose only contact, on 1.0.1,
    // was saved as a peer. The setup said nobody was paired.
    await partners.addContact(PartnerContact(
        id: 'p', displayName: 'PC 1', pairingCode: 'OLD333', pairingSecret: 's', role: PartnerRole.peer));
    await partners.addContact(PartnerContact(
        id: 'd', displayName: 'Switchy', pairingCode: 'SWI444', pairingSecret: 's', role: PartnerRole.dominant));
    await sync.handleIncomingSyncMessage(SyncMessage(
      type: SyncMessageType.featureHello,
      senderId: 'x',
      payload: {'senderCode': 'SWI444', 'features': ['chastityTimer']},
    ));

    await pump(tester, const TimerSetupView(role: TimerRole.director));

    expect(find.textContaining('Nobody is paired'), findsNothing);
    expect(find.textContaining("PC 1 can't use the Chastity Timer yet"), findsOneWidget);
    final switchy = tester.widget<RadioListTile<String?>>(find.widgetWithText(RadioListTile<String?>, 'Switchy'));
    expect(switchy.enabled, isTrue, reason: 'has the timer, whatever role it was saved with');
    await finish(tester);
  });

  testWidgets('with nobody paired at all, it says so', (tester) async {
    await pump(tester, const TimerSetupView(role: TimerRole.director));
    expect(find.textContaining('Nobody is paired yet'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('with no timer, the dashboard card offers to start one', (tester) async {
    await pump(tester, const Scaffold(body: TimerDashboardCard(role: TimerRole.player)));
    expect(find.text('CHASTITY TIMER'), findsOneWidget);
    expect(find.text('No timer running'), findsOneWidget);
    await finish(tester);
  });
}
