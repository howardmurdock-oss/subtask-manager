import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/chastity_timer.dart';
import 'package:orders_app/services/app_links.dart';
import 'package:orders_app/services/chastity_timer_service.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/public_order_bridge.dart';
import 'package:orders_app/views/chastity_timer/timer_profile_view.dart';
import 'package:orders_app/core/security/security_service.dart';
import 'package:orders_app/core/theme/theme_provider.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/views/settings/settings_view.dart';

/// The player's public page: one link for all their timers.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime.now().millisecondsSinceEpoch;
  late List<({String method, String path, String? key, Object? body})> calls;

  Map<String, dynamic> view(String id, String role) => {
        'id': id,
        'role': role,
        'manager': true,
        'status': 'running',
        'startAt': now,
        'endAt': now + 3600 * 1000,
        'config': {'baseSeconds': 3600},
        'history': const [],
        'now': now,
      };

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls = [];
    ChastityTimerService.request = (method, url, {key, body}) async {
      calls.add((method: method, path: url.path, key: key, body: body));
      final s = url.pathSegments;
      if (url.path == '/profile') {
        return const TimerApiResponse(200, {'profileId': 'prof-1', 'publicId': 'pub-1', 'key': 'PK', 'name': 'Toy'});
      }
      if (s.length >= 3 && s[0] == 'profile') {
        switch (s[2]) {
          case 'rekey':
            return key == 'OLD'
                ? const TimerApiResponse(200, {'publicId': 'pub-1', 'key': 'NEW', 'name': 'Toy', 'timers': <String>[]})
                : const TimerApiResponse(403, {'error': 'not your profile'});
          case 'new-link':
            return const TimerApiResponse(200, {'publicId': 'pub-2'});
          case 'settings':
            final b = body as Map;
            return TimerApiResponse(200, {
              'name': b['name'],
              'showHistory': b['showHistory'] == true,
              'bio': b['bio'],
              'socials': b['socials'] ?? [],
              'acceptMessages': b['acceptMessages'] == true,
              'unreadMessages': 0,
              'publicOrders': b['publicOrders'],
            });
          case 'messages':
            if (method == 'GET') {
              return const TimerApiResponse(200, {
                'messages': [
                  {
                    'id': 'msg-1',
                    'profileId': 'prof-1',
                    'senderName': 'Visitor 1',
                    'message': 'Hello there!',
                    'createdAt': 1000000,
                  }
                ],
                'unreadCount': 1,
              });
            }
            return const TimerApiResponse(200, {'ok': true});
          case 'chats':
            if (s.length == 3) {
              return const TimerApiResponse(200, {
                'threads': [
                  {
                    'visitorId': 'v-1',
                    'visitorName': 'Secret Admirer',
                    'lastMessage': 'You are doing great!',
                    'lastMessageAt': 2000000,
                    'unreadCount': 2,
                  }
                ],
              });
            }
            if (s.length == 4) {
              if (method == 'GET') {
                return const TimerApiResponse(200, {
                  'messages': [
                    {
                      'id': 'msg-c1',
                      'profileId': 'prof-1',
                      'visitorId': 'v-1',
                      'senderRole': 'visitor',
                      'senderName': 'Secret Admirer',
                      'text': 'You are doing great!',
                      'createdAt': 2000000,
                      'readAt': null,
                    }
                  ],
                });
              }
              if (method == 'POST') {
                return const TimerApiResponse(200, {'ok': true, 'id': 'reply-1'});
              }
              if (method == 'DELETE') {
                return const TimerApiResponse(200, {'ok': true});
              }
            }
            return const TimerApiResponse(200, {});
          case 'orders':
            if (method == 'GET') {
              return const TimerApiResponse(200, {
                'enabled': true,
                'skipsLeft': 3,
                'active': {
                  'no': 1,
                  'deliveredAt': 1000000,
                  'def': {
                    'id': 'ord-1',
                    'title': 'Test profile order',
                    'description': 'Do 10 pushups',
                    'rewardTokens': 10,
                  }
                },
                'feed': [],
              });
            }
            final b = body as Map;
            return TimerApiResponse(200, {
              'enabled': true,
              'skipsLeft': 2,
              'feed': [
                {'no': b['no'], 'status': b['result'] == 'submitted' ? 'submitted' : 'completed', 'title': 'Test profile order'}
              ],
            });
        }
        return const TimerApiResponse(200, {});
      }
      return TimerApiResponse(200, view(s[s.length - 2], key == 'D' ? 'director' : 'player'));
    };
  });

  Iterable<String> added() =>
      calls.where((c) => c.path.endsWith('/add')).map((c) => (c.body as Map)['timerId'] as String);

  test("making the page tells it of every timer the player is on - and not a director's own", () async {
    final service = ChastityTimerService();
    await service.load();
    await service.addShared(id: 'mine-1', role: TimerRole.player, key: 'P');
    await service.addShared(id: 'theirs-1', role: TimerRole.director, key: 'D');

    expect(await service.createProfile(name: 'Toy'), isNull);
    expect(service.profileLink, 'https://subtaskmanager.com/p/pub-1');
    expect(added(), ['mine-1']);
    expect(calls.firstWhere((c) => c.path.endsWith('/add')).key, 'PK', reason: "with the page's key");
  });

  test('a new timer joins once; one deleted from the device leaves', () async {
    final service = ChastityTimerService();
    await service.load();
    await service.createProfile();
    await service.addShared(id: 'mine-2', role: TimerRole.player, key: 'P');
    await pumpEventQueue();
    await service.refresh('mine-2');
    await pumpEventQueue();
    expect(added(), ['mine-2']);

    await service.forget('mine-2');
    expect(calls.where((c) => c.path.endsWith('/remove')).length, 1);
  });

  test('kept across a restart', () async {
    final service = ChastityTimerService();
    await service.load();
    await service.createProfile(name: 'Toy');
    final again = ChastityTimerService();
    await again.load();
    expect(again.profile?.publicId, 'pub-1');
    expect(again.profile?.name, 'Toy');
  });

  test('moving it: the code from one device is taken over on another, with a fresh key', () async {
    final service = ChastityTimerService();
    await service.load();
    expect(await service.importProfile('nonsense'), 'bad-code');
    expect(await service.importProfile('stp1.prof-1.WRONG'), 'bad-code');
    expect(await service.importProfile('stp1.prof-1.OLD'), isNull);
    expect(service.profile?.key, 'NEW', reason: 'the device it came from can no longer change it');
    expect(service.exportProfile(), 'stp1.prof-1.NEW');
  });

  test('a new link, and settings', () async {
    final service = ChastityTimerService();
    await service.load();
    await service.createProfile(name: 'Toy');
    await service.newProfileLink();
    expect(service.profileLink, 'https://subtaskmanager.com/p/pub-2');
    await service.updateProfile(showHistory: true);
    expect(service.profile?.showHistory, isTrue);
    await service.updateProfile(clearName: true);
    expect(service.profile?.name, isNull);
  });

  testWidgets('the page screen: make one, then manage it', (tester) async {
    final service = ChastityTimerService();
    await service.load();
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: service,
      child: const MaterialApp(home: TimerProfileView()),
    ));

    expect(find.text('Make my page'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Toy');
    await tester.tap(find.text('Make my page'));
    await tester.pumpAndSettle();

    expect(find.text('https://subtaskmanager.com/p/pub-1'), findsOneWidget);
    expect(find.text('Toy'), findsOneWidget);
    expect(find.text('Bio'), findsOneWidget);
    expect(find.text('Social links'), findsOneWidget);
    expect(find.text('Allow visitor messages'), findsOneWidget);
    expect(find.text('Allow orders without a timer'), findsOneWidget);
    expect(find.text('Configure orders'), findsNothing);

    // Toggle "Allow orders without a timer" on when orders list is currently empty
    await tester.tap(find.widgetWithText(SwitchListTile, 'Allow orders without a timer'));
    await tester.pumpAndSettle();

    expect(find.text('Configure orders'), findsOneWidget);
    expect(service.profile?.publicOrders?.enabled, isTrue);

    expect(find.text('Show past timers'), findsOneWidget);
    expect(find.text('Move to another device'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  test('updating bio, socials, acceptMessages, and publicOrders', () async {
    final service = ChastityTimerService();
    await service.load();
    await service.createProfile(name: 'Toy');

    await service.updateProfile(
      bio: 'Hello world from bio!',
      socials: const [
        ProfileSocial(id: 's-1', platform: 'reddit', label: 'u/myname', url: 'https://reddit.com/u/myname'),
        ProfileSocial(id: 's-2', platform: 'onlyfans', label: 'My VIP', url: 'https://onlyfans.com/myname'),
      ],
      acceptMessages: true,
      publicOrders: const PublicOrdersSettings(enabled: true, skipsPerDay: 5),
    );

    expect(service.profile?.bio, 'Hello world from bio!');
    expect(service.profile?.socials.length, 2);
    expect(service.profile?.socials[0].platform, 'reddit');
    expect(service.profile?.socials[1].platform, 'onlyfans');
    expect(service.profile?.acceptMessages, isTrue);
    expect(service.profile?.publicOrders?.enabled, isTrue);
    expect(service.profile?.publicOrders?.skipsPerDay, 5);

    // Clear bio
    await service.updateProfile(clearBio: true);
    expect(service.profile?.bio, isNull);
  });

  test('visitor messages: fetch, mark read, delete', () async {
    final service = ChastityTimerService();
    await service.load();
    await service.createProfile(name: 'Toy');

    final messages = await service.fetchProfileMessages();
    expect(messages.length, 1);
    expect(messages[0].id, 'msg-1');
    expect(messages[0].senderName, 'Visitor 1');
    expect(messages[0].message, 'Hello there!');
    expect(service.profile?.unreadMessages, 1);

    expect(await service.markProfileMessagesRead(all: true), isNull);
    expect(service.profile?.unreadMessages, 0);

    expect(await service.deleteProfileMessages(ids: ['msg-1']), isNull);
  });

  test('standalone profile orders delivered and submitted via PublicOrderBridge', () async {
    final service = ChastityTimerService();
    final engine = OrderEngine();
    await service.load();
    await service.createProfile(name: 'Toy');

    final bridge = PublicOrderBridge(engine: engine, timers: service);
    await bridge.start();

    // Fetch standalone orders on profile
    final orders = await service.fetchProfileOrders();
    expect(orders?.active?.def.title, 'Test profile order');

    // Bridge delivers to engine
    final active = bridge.currentFor('profile');
    expect(active, isNotNull);
    expect(active!.id, 'public-profile-1');
    expect(active.order.title, 'Test profile order');
    expect(bridge.skipsLeftFor(active), 3);

    // Destination of profile order is issuer or none (not director)
    final dest = bridge.destinationOf(active);
    expect(dest?.to, PublicProofDestination.none);
    expect(dest?.directorCode, isNull);

    // Submit the profile order
    final error = await bridge.submit(active, note: 'Done!');
    expect(error, isNull);

    bridge.dispose();
  });

  test('visitor chats: fetch threads, fetch messages, reply, delete thread, and app_links routing', () async {
    final service = ChastityTimerService();
    await service.load();
    await service.createProfile(name: 'Toy');

    // Fetch chat threads
    final threads = await service.fetchProfileChatThreads();
    expect(threads.length, 1);
    expect(threads[0].visitorId, 'v-1');
    expect(threads[0].visitorName, 'Secret Admirer');
    expect(threads[0].lastMessage, 'You are doing great!');
    expect(threads[0].unreadCount, 2);
    expect(threads[0].hasUnread, isTrue);

    // Fetch messages in thread
    final messages = await service.fetchProfileChatMessages('v-1');
    expect(messages.length, 1);
    expect(messages[0].id, 'msg-c1');
    expect(messages[0].isFromVisitor, isTrue);
    expect(messages[0].isFromPlayer, isFalse);
    expect(messages[0].text, 'You are doing great!');

    // Reply
    final replyErr = await service.sendProfileChatReply('v-1', 'Thank you so much!');
    expect(replyErr, isNull);

    // Block visitor
    expect(service.isVisitorBlocked('v-1'), isFalse);
    final blocked = await service.toggleBlockVisitor('v-1');
    expect(blocked, isTrue);
    expect(service.isVisitorBlocked('v-1'), isTrue);

    // Threads reflect blocked status
    final threadsAfterBlock = await service.fetchProfileChatThreads();
    expect(threadsAfterBlock[0].isBlocked, isTrue);

    // Unblock visitor
    final unblocked = await service.toggleBlockVisitor('v-1');
    expect(unblocked, isFalse);
    expect(service.isVisitorBlocked('v-1'), isFalse);

    // Delete thread
    final delErr = await service.deleteProfileChatThread('v-1');
    expect(delErr, isNull);

    // Deep link routing
    final standardLink = AppLinks.publicPageOf(Uri.parse('subtaskmanager://p/pub-12345'));
    expect(standardLink?.kind, 'p');
    expect(standardLink?.id, 'pub-12345');
    expect(standardLink?.chat, isFalse);

    final chatLink = AppLinks.publicPageOf(Uri.parse('subtaskmanager://p/pub-12345/chat'));
    expect(chatLink?.kind, 'p');
    expect(chatLink?.id, 'pub-12345');
    expect(chatLink?.chat, isTrue);

    final chatLinkSlash = AppLinks.publicPageOf(Uri.parse('subtaskmanager:/p/pub-12345/chat'));
    expect(chatLinkSlash?.kind, 'p');
    expect(chatLinkSlash?.id, 'pub-12345');
    expect(chatLinkSlash?.chat, isTrue);
  });

  testWidgets('settings page gives access to public profile page', (tester) async {
    final timerService = ChastityTimerService();
    await timerService.load();
    final engine = OrderEngine();
    await engine.init();
    final sync = SyncService(engine);
    await sync.init(deferNetwork: true);
    final themeProvider = ThemeProvider();
    final security = SecurityService();

    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: themeProvider),
          ChangeNotifierProvider.value(value: security),
          ChangeNotifierProvider.value(value: sync),
          ChangeNotifierProvider.value(value: timerService),
        ],
        child: const MaterialApp(home: SettingsView()),
      ),
    );

    // Initial state without profile: shows not set up
    expect(find.text('PUBLIC PROFILE PAGE'), findsOneWidget);
    expect(find.text('Not set up yet'), findsOneWidget);
    expect(find.text('Public Profile Page'), findsOneWidget);

    // Create profile
    await timerService.createProfile(name: 'Alice');
    await tester.pumpAndSettle();

    // Now shows active link
    expect(find.text(timerService.profileLink!), findsOneWidget);
    expect(find.byTooltip('Copy Public Link'), findsOneWidget);

    // Tap to open public profile view
    await tester.tap(find.text('PUBLIC PROFILE PAGE'));
    await tester.pumpAndSettle();

    // Should be on TimerProfileView
    expect(find.text('Your public page'), findsOneWidget);
    expect(find.text('Bio'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    sync.dispose();
    engine.dispose();
  });
}

