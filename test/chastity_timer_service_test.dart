import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/chastity_timer.dart';
import 'package:orders_app/services/chastity_timer_service.dart';

/// The app's side of the timer: which timers this device can reach, with
/// which key, and what the Worker last said about each. The Worker's own
/// rules are tested in worker/test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> view({
    String id = 't1',
    String role = 'player',
    bool manager = true,
    String status = 'running',
    int? endAt,
    bool hidden = false,
    int? serverNow,
  }) =>
      {
        'id': id,
        'role': role,
        'manager': manager,
        'status': status,
        'startAt': now,
        'endAt': endAt,
        'releasedAt': null,
        'releasedBy': null,
        'config': {
          'baseSeconds': 3600,
          'hidden': hidden,
          'combination': {'enabled': true, 'length': 4, 'digits': null},
        },
        'history': [
          {'id': 'director-1', 'at': now, 'actor': 'director', 'delta': hidden ? null : 600},
        ],
        'publicId': null,
        'now': serverNow ?? now,
      };

  late List<({String method, Uri url, String? key, Object? body})> calls;

  void serve(TimerApiResponse Function(String method, Uri url, String? key, Object? body) handler) {
    ChastityTimerService.request = (method, url, {key, body}) async {
      calls.add((method: method, url: url, key: key, body: body));
      return handler(method, url, key, body);
    };
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls = [];
  });

  test('creating a timer keeps this side\'s key and hands back the other', () async {
    serve((method, url, key, body) {
      if (url.path.endsWith('/timer')) {
        return const TimerApiResponse(200, {'id': 't1', 'playerKey': 'P-KEY', 'directorKey': 'D-KEY'});
      }
      return TimerApiResponse(200, view(role: 'director', endAt: now + 3600 * 1000));
    });
    final service = ChastityTimerService();

    final result = await service.create(
      config: const ChastityTimerConfig(baseSeconds: 3600),
      role: TimerRole.director,
      partnerCode: 'ABC123',
      partnerName: 'PC 1',
    );

    expect(result.error, isNull);
    expect(result.partnerKey, 'P-KEY', reason: "the player's key goes to the player");
    expect(service.recordOf('t1')!.key, 'D-KEY');
    expect(service.recordOf('t1')!.partnerCode, 'ABC123');
    expect(calls.last.key, 'D-KEY', reason: 'the view is asked for with this side\'s key');
    expect(service.viewOf('t1')!.role, TimerRole.director);
  });

  test('timers are remembered across a restart', () async {
    serve((_, __, ___, ____) => const TimerApiResponse(200, {'id': 't1', 'playerKey': 'P', 'directorKey': 'D'}));
    await ChastityTimerService().create(config: const ChastityTimerConfig(baseSeconds: 60), role: TimerRole.player);

    final reloaded = ChastityTimerService();
    await reloaded.load();
    expect(reloaded.records.single.id, 't1');
    expect(reloaded.records.single.key, 'P');
  });

  test('a shared timer is added with the key the partner sent', () async {
    serve((_, __, ___, ____) => TimerApiResponse(200, view()));
    final service = ChastityTimerService();

    await service.addShared(id: 't1', role: TimerRole.player, key: 'P-KEY', partnerName: 'Tessa');

    expect(service.recordOf('t1')!.role, TimerRole.player);
    expect(calls.single.key, 'P-KEY');
  });

  test('a change sends the amount in seconds, with this device\'s key', () async {
    serve((method, url, key, body) => TimerApiResponse(200, view(endAt: now + 7200 * 1000)));
    final service = ChastityTimerService();
    await service.addShared(id: 't1', role: TimerRole.director, key: 'D-KEY');

    final error = await service.adjust('t1', const Duration(minutes: -30));

    expect(error, isNull);
    expect(calls.last.url.path, endsWith('/timer/t1/adjust'));
    expect(calls.last.key, 'D-KEY');
    expect((calls.last.body as Map)['delta'], -1800);
  });

  test('a refused change reports why, and still shows the timer as it stands', () async {
    serve((method, url, key, body) => url.path.endsWith('/adjust')
        ? TimerApiResponse(409, {...view(endAt: now + 5000 * 1000), 'error': 'daily-cap'})
        : TimerApiResponse(200, view(endAt: now + 3600 * 1000)));
    final service = ChastityTimerService();
    await service.addShared(id: 't1', role: TimerRole.director, key: 'D-KEY');

    final error = await service.adjust('t1', const Duration(hours: 1));

    expect(error, 'daily-cap');
    expect(describeTimerError(error), contains("today's limit"));
    expect(service.viewOf('t1')!.endAt!.millisecondsSinceEpoch, now + 5000 * 1000);
  });

  test('without a connection, an action fails quietly with a reason', () async {
    ChastityTimerService.request = (_, __, {key, body}) async => throw const SocketExceptionForTest();
    final service = ChastityTimerService();
    await service.addShared(id: 't1', role: TimerRole.player, key: 'P');

    expect(await service.release('t1'), 'offline');
  });

  test('a hidden timer has no time left to show the player', () {
    final v = ChastityTimerView.fromJson(view(hidden: true));
    expect(v.remaining, isNull);
    expect(v.history.single.deltaSeconds, isNull);
    expect(v.history.single.actor, TimerActor.director);
  });

  test("the countdown follows the Worker's clock, not a wrong device clock", () {
    // The device is an hour slow: the Worker says it is an hour later.
    final serverNow = now + 3600 * 1000;
    final v = ChastityTimerView.fromJson(view(endAt: serverNow + 600 * 1000, serverNow: serverNow),
        receivedAt: DateTime.fromMillisecondsSinceEpoch(now));
    expect(v.remaining!.inMinutes, inInclusiveRange(9, 10));
  });

  group('when a timer ends', () {
    test('it is announced once, and stays in front of its person until seen', () async {
      serve((_, __, ___, ____) => TimerApiResponse(200, view(status: 'ended', endAt: now - 1000)));
      final service = ChastityTimerService();
      final announced = <String>[];
      service.justFinished.listen((v) => announced.add(v.id));

      await service.addShared(id: 't1', role: TimerRole.player, key: 'P');
      await service.refresh('t1');
      await Future<void>.delayed(Duration.zero);

      expect(announced, ['t1'], reason: 'once, however often it is fetched');
      expect(service.finishedUnseen(role: TimerRole.player).single.id, 't1');
      expect(service.active(role: TimerRole.player), isEmpty);

      await service.acknowledge('t1');
      expect(service.finishedUnseen(role: TimerRole.player), isEmpty);
    });

    test('having seen it is remembered across a restart', () async {
      serve((_, __, ___, ____) => TimerApiResponse(200, view(status: 'ended', endAt: now - 1000)));
      final first = ChastityTimerService();
      await first.addShared(id: 't1', role: TimerRole.player, key: 'P');
      await first.acknowledge('t1');

      final second = ChastityTimerService();
      await second.load();
      final announced = <String>[];
      second.justFinished.listen((v) => announced.add(v.id));
      await second.refresh('t1');
      await Future<void>.delayed(Duration.zero);

      expect(announced, isEmpty);
      expect(second.needsAttention('t1'), isFalse);
    });

    test('a timer whose end passes while the app is open is fetched again', () async {
      var ended = false;
      serve((_, __, ___, ____) => TimerApiResponse(
          200,
          ended
              ? view(status: 'ended', endAt: now - 1000)
              : view(endAt: DateTime.now().millisecondsSinceEpoch + 150)));
      final service = ChastityTimerService();
      await service.addShared(id: 't1', role: TimerRole.player, key: 'P');
      final finished = service.justFinished.first;

      ended = true;
      service.startWatching(every: const Duration(milliseconds: 50));
      final v = await finished.timeout(const Duration(seconds: 2));
      service.dispose();

      expect(v.status, TimerStatus.ended);
    });
  });

  test('a key sent again replaces the one that never worked', () async {
    serve((_, __, ___, ____) => TimerApiResponse(200, view()));
    final service = ChastityTimerService();
    await service.addShared(id: 't1', role: TimerRole.director, key: 'OLD', partnerName: 'Tessa');
    await service.addShared(id: 't1', role: TimerRole.director, key: 'NEW');

    expect(service.records.single.key, 'NEW');
    expect(service.records.single.partnerName, 'Tessa', reason: 'kept from the first time');
  });

  test("a fresh key for the partner is asked for with the manager's key", () async {
    serve((method, url, key, body) => url.path.endsWith('/reissue-key')
        ? const TimerApiResponse(200, {'key': 'FRESH'})
        : TimerApiResponse(200, view()));
    final service = ChastityTimerService();
    await service.addShared(id: 't1', role: TimerRole.player, key: 'P');

    final result = await service.reissuePartnerKey('t1');

    expect(result.key, 'FRESH');
    expect(calls.last.url.path, endsWith('/timer/t1/reissue-key'));
    expect(calls.last.key, 'P');
  });

  test('forgetting a timer removes it from this device only', () async {
    serve((_, __, ___, ____) => TimerApiResponse(200, view()));
    final service = ChastityTimerService();
    await service.addShared(id: 't1', role: TimerRole.player, key: 'P');
    final before = calls.length;

    await service.forget('t1');

    expect(service.records, isEmpty);
    expect(calls.length, before, reason: 'nothing is sent to the Worker');
  });
}

class SocketExceptionForTest implements Exception {
  const SocketExceptionForTest();
}
