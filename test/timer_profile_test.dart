import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/chastity_timer.dart';
import 'package:orders_app/services/chastity_timer_service.dart';
import 'package:orders_app/views/chastity_timer/timer_profile_view.dart';

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
      if (s.length == 3 && s[0] == 'profile') {
        switch (s[2]) {
          case 'rekey':
            return key == 'OLD'
                ? const TimerApiResponse(200, {'publicId': 'pub-1', 'key': 'NEW', 'name': 'Toy', 'timers': <String>[]})
                : const TimerApiResponse(403, {'error': 'not your profile'});
          case 'new-link':
            return const TimerApiResponse(200, {'publicId': 'pub-2'});
          case 'settings':
            final b = body as Map;
            return TimerApiResponse(200, {'name': b['name'], 'showHistory': b['showHistory'] == true});
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
    expect(find.text('Show past timers'), findsOneWidget);
    expect(find.text('Move to another device'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
