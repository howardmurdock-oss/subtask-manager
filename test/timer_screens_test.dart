import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  /// A timer with no end time, started two hours ago.
  Map<String, dynamic> openView({required String role, required String managedBy, String? releasedBy}) => {
        'id': 't1',
        'role': role,
        'manager': role == managedBy,
        'status': releasedBy == null ? 'running' : 'released',
        'startAt': now - 2 * 3600 * 1000,
        'endAt': null,
        'closedAt': releasedBy == null ? null : now - 600 * 1000,
        'releasedAt': releasedBy == null ? null : now - 600 * 1000,
        'releasedBy': releasedBy,
        'config': {
          'baseSeconds': 3600,
          'openEnded': true,
          'hidden': false,
          'director': {'canAdd': true, 'canRemove': true, 'dailyCapSeconds': 3600},
          'public': {'enabled': false},
          'combination': {'enabled': false},
        },
        'history': const [],
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
    await tester.scrollUntilVisible(find.text('+10 minutes'), 300, scrollable: find.byType(Scrollable).first);
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

  testWidgets("the end of the setup page is not hidden behind Android's navigation bar", (tester) async {
    // Android draws apps behind the system navigation bar; the last lines of
    // the page sat underneath it.
    tester.view.padding = const FakeViewPadding(bottom: 48);
    addTearDown(tester.view.resetPadding);
    await pump(tester, const TimerSetupView(role: TimerRole.director));

    await tester.drag(find.byType(ListView), const Offset(0, -5000));
    await tester.pumpAndSettle();

    final last = find.textContaining('You will be told if they do');
    expect(tester.getRect(last).bottom, lessThanOrEqualTo(1400 - 48));
    await finish(tester);
  });

  testWidgets('the length dialog says which box is which, and spells out the total', (tester) async {
    Duration? picked;
    await pump(tester, Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () async => picked = await showDurationDialog(context, title: 'Starts at'),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('days'), findsOneWidget);
    expect(find.text('hours'), findsOneWidget);
    expect(find.text('minutes'), findsOneWidget);

    final boxes = find.byType(TextField);
    await tester.enterText(boxes.at(0), '1');
    await tester.enterText(boxes.at(1), '4');
    await tester.enterText(boxes.at(2), '30');
    await tester.pump();
    expect(find.text('= 1 day 4 hours 30 minutes'), findsOneWidget);

    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    expect(picked, const Duration(days: 1, hours: 4, minutes: 30));
    await finish(tester);
  });

  testWidgets('with nobody paired at all, it says so', (tester) async {
    await pump(tester, const TimerSetupView(role: TimerRole.director));
    expect(find.textContaining('Nobody is paired yet'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a finished timer stays on the card until seen, pointing at the combination', (tester) async {
    ChastityTimerService.request =
        (m, u, {key, body}) async => TimerApiResponse(200, view(role: 'player', over: true, digits: '4821'));
    await timers.addShared(id: 't1', role: TimerRole.player, key: 'P');

    await pump(tester, const Scaffold(body: TimerDashboardCard(role: TimerRole.player)));
    expect(find.text('Timer finished'), findsOneWidget);
    expect(find.text('Your combination is ready. Tap to see it.'), findsOneWidget);
    expect(find.text('No timer running'), findsNothing);

    await timers.acknowledge('t1');
    await tester.pump();
    expect(find.text('No timer running'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('opening a finished timer counts as seeing it', (tester) async {
    ChastityTimerService.request =
        (m, u, {key, body}) async => TimerApiResponse(200, view(role: 'player', over: true, digits: '4821'));
    await timers.addShared(id: 't1', role: TimerRole.player, key: 'P');
    expect(timers.needsAttention('t1'), isTrue);

    await pump(tester, const TimerDetailView(timerId: 't1'));
    await tester.pump();

    expect(timers.needsAttention('t1'), isFalse);
    await finish(tester);
  });

  testWidgets('at the maximum, adding is not offered, and it says why', (tester) async {
    ChastityTimerService.request = (m, u, {key, body}) async =>
        TimerApiResponse(200, {...view(role: 'director', digits: '4821'), 'atMaximum': true});
    await timers.addShared(id: 't1', role: TimerRole.director, key: 'D', partnerName: 'PC 1');

    await pump(tester, const TimerDetailView(timerId: 't1'));

    expect(find.textContaining('at its maximum length'), findsOneWidget);
    expect(find.text('ADD TIME'), findsNothing);
    expect(find.text('REMOVE TIME'), findsOneWidget, reason: 'removing still works');
    await finish(tester);
  });

  testWidgets('a player given the link can copy and open it, but not replace it', (tester) async {
    final shared = view(role: 'player');
    (shared['config'] as Map)['public'] = {'enabled': true, 'shareWithPlayer': true, 'stepSeconds': 600};
    shared['publicId'] = 'abc123XYZ';
    ChastityTimerService.request = (m, u, {key, body}) async => TimerApiResponse(200, shared);
    await timers.addShared(id: 't1', role: TimerRole.player, key: 'P', partnerName: 'Tessa');

    await pump(tester, const TimerDetailView(timerId: 't1'));

    expect(find.text('https://subtaskmanager.com/t/abc123XYZ'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('New link'), findsNothing);
    expect(find.text('Give your player the link too'), findsNothing);
    await finish(tester);
  });

  testWidgets('the director can give the player the link from the timer screen', (tester) async {
    final director = view(role: 'director');
    (director['config'] as Map)['public'] = {'enabled': true, 'stepSeconds': 600};
    director['publicId'] = 'abc123XYZ';
    ChastityTimerService.request = (m, u, {key, body}) async => TimerApiResponse(200, director);
    await timers.addShared(id: 't1', role: TimerRole.director, key: 'D', partnerName: 'PC 1');

    await pump(tester, const TimerDetailView(timerId: 't1'));

    expect(find.text('Give your player the link too'), findsOneWidget);
    expect(find.text('New link'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a public timer can be embedded: a widget for websites, an image for forums', (tester) async {
    final director = view(role: 'director');
    (director['config'] as Map)['public'] = {'enabled': true, 'stepSeconds': 600};
    director['publicId'] = 'abc123XYZ';
    ChastityTimerService.request = (m, u, {key, body}) async => TimerApiResponse(200, director);
    await timers.addShared(id: 't1', role: TimerRole.director, key: 'D', partnerName: 'PC 1');
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await pump(tester, const TimerDetailView(timerId: 't1'));
    await tester.ensureVisible(find.text('Embed'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Embed'));
    await tester.pumpAndSettle();

    const link = 'https://subtaskmanager.com/t/abc123XYZ';
    expect(find.text('Embed this timer'), findsOneWidget);
    expect(find.text('<iframe src="$link/embed" width="340" height="150" style="border:0;max-width:100%" title="Chastity Timer"></iframe>'), findsOneWidget);
    expect(find.text('[url=$link][img]$link/badge.svg[/img][/url]'), findsOneWidget);
    expect(find.text('[![Chastity Timer]($link/badge.svg)]($link)'), findsOneWidget);
    expect(find.text('[url=$link][img]$link/badge.png[/img][/url]'), findsOneWidget);
    expect(find.textContaining('just paste the link'), findsOneWidget);

    await tester.tap(find.descendant(
      of: find.widgetWithText(Card, 'Forum (BBCode)'),
      matching: find.text('Copy'),
    ));
    await tester.pumpAndSettle();
    expect(copied, '[url=$link][img]$link/badge.svg[/img][/url]');
    await finish(tester);
  });

  testWidgets("a partner who never received the timer is pointed out, with a way to send it again", (tester) async {
    final mine = view(role: 'player');
    mine['manager'] = true;
    mine['partnerConnected'] = false;
    final asked = <String>[];
    ChastityTimerService.request = (m, u, {key, body}) async {
      asked.add(u.path);
      return u.path.endsWith('/reissue-key')
          ? const TimerApiResponse(200, {'key': 'FRESH-KEY'})
          : TimerApiResponse(200, mine);
    };
    await partners.addContact(PartnerContact(
        id: 'sir', displayName: 'Sir', pairingCode: 'SIR123', pairingSecret: 's', role: PartnerRole.dominant));
    await timers.addShared(id: 't1', role: TimerRole.player, key: 'P', partnerCode: 'SIR123', partnerName: 'Sir');

    await pump(tester, const TimerDetailView(timerId: 't1'));
    expect(find.text("Sir hasn't received this timer yet"), findsOneWidget);

    await tester.tap(find.text('Send again'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(asked.where((p) => p.endsWith('/reissue-key')), hasLength(1));
    await finish(tester);
  });

  testWidgets('once the partner has connected, there is nothing to send again', (tester) async {
    final mine = view(role: 'player');
    mine['manager'] = true;
    mine['partnerConnected'] = true;
    ChastityTimerService.request = (m, u, {key, body}) async => TimerApiResponse(200, mine);
    await timers.addShared(id: 't1', role: TimerRole.player, key: 'P', partnerCode: 'SIR123', partnerName: 'Sir');

    await pump(tester, const TimerDetailView(timerId: 't1'));
    expect(find.textContaining("hasn't received this timer"), findsNothing);
    await finish(tester);
  });

  testWidgets('with no timer, the dashboard card offers to start one', (tester) async {
    await pump(tester, const Scaffold(body: TimerDashboardCard(role: TimerRole.player)));
    expect(find.text('CHASTITY TIMER'), findsOneWidget);
    expect(find.text('No timer running'), findsOneWidget);
    await finish(tester);
  });
  testWidgets('a running timer also shows how long it has been locked', (tester) async {
    final v = view(role: 'player')..['startAt'] = now - 90 * 60 * 1000;
    ChastityTimerService.request = (m, u, {key, body}) async => TimerApiResponse(200, v);
    await timers.addShared(id: 't1', role: TimerRole.player, key: 'P');

    await pump(tester, const TimerDetailView(timerId: 't1'));

    expect(find.text('left'), findsOneWidget);
    expect(find.text('Locked for 1 hour 30 minutes so far'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a finished timer says how long it ran', (tester) async {
    final v = view(role: 'player', over: true)..['startAt'] = now - 3 * 3600 * 1000 - 1000;
    v['closedAt'] = now - 1000;
    ChastityTimerService.request = (m, u, {key, body}) async => TimerApiResponse(200, v);
    await timers.addShared(id: 't1', role: TimerRole.player, key: 'P');

    await pump(tester, const TimerDetailView(timerId: 't1'));

    expect(find.text('Ran for 3 hours'), findsOneWidget);
    await finish(tester);
  });

  testWidgets("a player's own timer with no end time counts up, and they simply end it", (tester) async {
    ChastityTimerService.request =
        (m, u, {key, body}) async => TimerApiResponse(200, openView(role: 'player', managedBy: 'player'));
    await timers.addShared(id: 't1', role: TimerRole.player, key: 'P');

    await pump(tester, const TimerDetailView(timerId: 't1'));

    expect(find.textContaining('02:00:0'), findsOneWidget);
    expect(find.text('locked so far · no end time'), findsOneWidget);
    expect(find.text('End timer'), findsOneWidget);
    expect(find.text('Emergency release'), findsNothing, reason: 'ending it costs them nothing');
    expect(find.text('ADD TIME'), findsNothing, reason: 'there is no end to move');
    await finish(tester);
  });

  testWidgets("a director's timer with no end time: they end it, the player keeps the emergency release",
      (tester) async {
    ChastityTimerService.request =
        (m, u, {key, body}) async => TimerApiResponse(200, openView(role: 'director', managedBy: 'director'));
    await timers.addShared(id: 't1', role: TimerRole.director, key: 'D', partnerName: 'PC 1');
    await pump(tester, const TimerDetailView(timerId: 't1'));
    expect(find.text('End the timer now'), findsOneWidget);
    expect(find.text('ADD TIME'), findsNothing);
    expect(find.text('REMOVE TIME'), findsNothing);
    await finish(tester);

    ChastityTimerService.request =
        (m, u, {key, body}) async => TimerApiResponse(200, openView(role: 'player', managedBy: 'director')..['id'] = 't2');
    await timers.addShared(id: 't2', role: TimerRole.player, key: 'P');
    await pump(tester, const TimerDetailView(timerId: 't2'));
    expect(find.text('Emergency release'), findsOneWidget);
    expect(find.text('End timer'), findsNothing);
    await finish(tester);
  });

  testWidgets('a timer the player ended themselves is not called an emergency release', (tester) async {
    ChastityTimerService.request = (m, u, {key, body}) async =>
        TimerApiResponse(200, openView(role: 'director', managedBy: 'player', releasedBy: 'player'));
    await timers.addShared(id: 't1', role: TimerRole.director, key: 'D', partnerName: 'PC 1');

    await pump(tester, const TimerDetailView(timerId: 't1'));

    expect(find.text('Ended by your player'), findsOneWidget);
    expect(find.text('Ran for 1 hour 50 minutes'), findsOneWidget);
    expect(find.textContaining('emergency'), findsNothing);
    await finish(tester);
  });

  testWidgets('choosing no end time hides everything that moves the end', (tester) async {
    await pump(tester, const TimerSetupView(role: TimerRole.player));

    expect(find.text('Starts at'), findsOneWidget);
    expect(find.text('RANDOM CHANGES'), findsOneWidget);
    await tester.tap(find.text('No end time'));
    await tester.pump();

    expect(find.text('Starts at'), findsNothing);
    expect(find.text('RANDOM CHANGES'), findsNothing);
    expect(find.text('End by itself eventually'), findsNothing,
        reason: 'their own timer, ended when they like: a limit would make it a timed lock');
    expect(find.text('Maximum length'), findsNothing);
    expect(find.text('Share a public link'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('setting up: tell them when time is added, in your own words, always saying who', (tester) async {
    await pump(tester, const TimerSetupView(role: TimerRole.player));

    expect(find.text('NOTIFICATIONS'), findsOneWidget);
    expect(find.text('Tell me when time is added'), findsOneWidget);
    expect(find.text('"10 minutes was added by the public."'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '{time} more of suffering, Toy');
    await tester.pump();
    expect(find.text('"10 minutes more of suffering, Toy, added by the public."'), findsOneWidget);

    await tester.tap(find.text('No end time'));
    await tester.pump();
    expect(find.text('NOTIFICATIONS'), findsNothing, reason: 'nothing is ever added to it');
    await finish(tester);
  });

  testWidgets('a running timer: its manager can switch notifications and change the message', (tester) async {
    final v = view(role: 'director');
    (v['config'] as Map)['notify'] = {'onAdd': true, 'message': 'Suffer more, Toy!'};
    ChastityTimerService.request = (m, u, {key, body}) async => TimerApiResponse(200, v);
    await timers.addShared(id: 't1', role: TimerRole.director, key: 'D', partnerName: 'PC 1');

    await pump(tester, const TimerDetailView(timerId: 't1'));

    expect(find.text('Tell your player when time is added'), findsOneWidget);
    expect(find.text('Suffer more, Toy! Added by your Director.'), findsOneWidget);
    expect(find.text('Change the message'), findsOneWidget);
    await finish(tester);
  });

  testWidgets("the player doesn't manage a director's notifications", (tester) async {
    ChastityTimerService.request = (m, u, {key, body}) async => TimerApiResponse(200, view(role: 'player'));
    await timers.addShared(id: 't1', role: TimerRole.player, key: 'P');
    await pump(tester, const TimerDetailView(timerId: 't1'));
    expect(find.text('NOTIFICATIONS'), findsNothing);
    await finish(tester);
  });

  testWidgets('a director can offer tokens for completing it; a player cannot reward themselves', (tester) async {
    await pump(tester, const TimerSetupView(role: TimerRole.director));
    await tester.scrollUntilVisible(find.text('Reward tokens for completing it'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Reward tokens for completing it'), findsOneWidget);
    await finish(tester);

    await pump(tester, const TimerSetupView(role: TimerRole.player));
    await tester.scrollUntilVisible(find.text('COMBINATION'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('REWARD'), findsNothing);
    await finish(tester);
  });

  testWidgets('the player sees the reward on offer, then that they earned it', (tester) async {
    final running = view(role: 'player');
    (running['config'] as Map)['rewardTokens'] = 50;
    ChastityTimerService.request = (m, u, {key, body}) async => TimerApiResponse(200, running);
    await timers.addShared(id: 't1', role: TimerRole.player, key: 'P');
    await pump(tester, const TimerDetailView(timerId: 't1'));
    expect(find.text('Complete it to earn 50 tokens. Not if you use the emergency release.'), findsOneWidget);
    await finish(tester);

    final over = view(role: 'player', over: true)..['id'] = 't2';
    (over['config'] as Map)['rewardTokens'] = 50;
    ChastityTimerService.request = (m, u, {key, body}) async => TimerApiResponse(200, over);
    await timers.addShared(id: 't2', role: TimerRole.player, key: 'P');
    await pump(tester, const TimerDetailView(timerId: 't2'));
    expect(find.text('You earned 50 tokens.'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('the director can set a reward on a running timer', (tester) async {
    ChastityTimerService.request = (m, u, {key, body}) async => TimerApiResponse(200, view(role: 'director'));
    await timers.addShared(id: 't1', role: TimerRole.director, key: 'D', partnerName: 'PC 1');
    await pump(tester, const TimerDetailView(timerId: 't1'));
    expect(find.text('No reward for completing it.'), findsOneWidget);
    expect(find.text('Set a reward'), findsOneWidget);
    await finish(tester);
  });
}
