import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/chastity_timer.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/services/chastity_timer_service.dart';
import 'package:orders_app/services/timer_notice.dart';
import 'package:orders_app/views/chastity_timer/timer_format.dart';

/// Telling the player when time is added: the words, and announcing public
/// additions only once, and only ones that happened.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the words', () {
    test('plain, unless the manager wrote their own', () {
      expect(addedNotice(amount: const Duration(minutes: 10), by: TimerActor.director),
          '10 minutes was added by your Director.');
      expect(addedNotice(amount: const Duration(hours: 1), by: TimerActor.public), '1 hour was added by the public.');
    });

    test('their own words always end with who added it', () {
      expect(
          addedNotice(
              message: '{time} more of suffering, Toy', amount: const Duration(minutes: 10), by: TimerActor.director),
          '10 minutes more of suffering, Toy, added by your Director.');
      expect(addedNotice(message: 'Suffer more, Toy!', amount: const Duration(minutes: 5), by: TimerActor.public),
          'Suffer more, Toy! Added by the public.');
      expect(addedNotice(message: 'more time.', by: TimerActor.director), 'More time, added by your Director.');
    });

    test('a hidden amount is never given away', () {
      expect(addedNotice(by: TimerActor.director), 'Time was added by your Director.');
      expect(addedNotice(message: '{time} more, Toy', by: TimerActor.public), 'Some time more, Toy, added by the public.');
    });
  });

  group('public additions', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    late List<Map<String, dynamic>> history;
    late Map<String, dynamic> config;
    var fetches = 0;

    Map<String, dynamic> view() => {
          'id': 't1',
          'role': 'player',
          'manager': false,
          'status': 'running',
          'startAt': now - 3600 * 1000,
          'endAt': now + 3600 * 1000,
          'config': config,
          'history': history,
          'now': now,
        };

    SyncMessage wake([String id = 'w1']) => SyncMessage(
        id: id, type: SyncMessageType.timerChanged, senderId: 'timer-service', payload: {'timerId': 't1', 'check': 'public'});

    setUp(() async {
      fetches = 0;
      history = [];
      config = {'baseSeconds': 7200, 'notify': {'onAdd': true, 'message': null}, 'public': {'enabled': true}};
      SharedPreferences.setMockInitialValues({
        ChastityTimerService.recordsKey:
            '[{"id":"t1","role":"player","key":"P","addedAt":"2026-10-01T00:00:00.000"}]',
      });
      ChastityTimerService.request = (method, url, {key, body}) async {
        fetches++;
        expect(key, 'P', reason: 'fetched with this device\'s own key');
        return TimerApiResponse(200, view());
      };
      await TimerNotice.startCounting('t1', DateTime.fromMillisecondsSinceEpoch(now - 60 * 1000));
    });

    test('votes since the last notice are added up into one', () async {
      history = [
        {'id': 'a', 'at': now - 30 * 1000, 'actor': 'public', 'delta': 600},
        {'id': 'b', 'at': now - 20 * 1000, 'actor': 'public', 'delta': 600},
        {'id': 'c', 'at': now - 10 * 1000, 'actor': 'director', 'delta': 600},
      ];
      expect(await TimerNotice.announce(wake()), isTrue);
      expect(fetches, 1);
    });

    test('a wake-up with nothing new behind it - forged, or repeated - announces nothing', () async {
      expect(await TimerNotice.announce(wake()), isFalse, reason: 'no public additions at all');
      history = [{'id': 'old', 'at': now - 120 * 1000, 'actor': 'public', 'delta': 600}];
      expect(await TimerNotice.announce(wake('w2')), isFalse, reason: 'from before this device was counting');
    });

    test('each addition is announced once, and each wake-up handled once', () async {
      history = [{'id': 'a', 'at': now - 30 * 1000, 'actor': 'public', 'delta': 600}];
      expect(await TimerNotice.announce(wake()), isTrue);
      expect(await TimerNotice.announce(wake()), isFalse, reason: 'the same message by another path');
      expect(fetches, 1);
      expect(await TimerNotice.announce(wake('w2')), isFalse, reason: 'already announced');
    });

    test('switched off, nothing is announced', () async {
      config = {...config, 'notify': {'onAdd': false}};
      history = [{'id': 'a', 'at': now - 30 * 1000, 'actor': 'public', 'delta': 600}];
      expect(await TimerNotice.announce(wake()), isFalse);
    });
  });

  test("a player's timer is told where this device listens, once", () async {
    SharedPreferences.setMockInitialValues({});
    final now = DateTime.now().millisecondsSinceEpoch;
    final calls = <String>[];
    ChastityTimerService.ownTopic = () => 'orders_relay_0123456789abcdef01234567';
    ChastityTimerService.request = (method, url, {key, body}) async {
      calls.add('$method ${url.path}');
      if (url.path.endsWith('/notify-topic')) {
        expect(body, {'topic': 'orders_relay_0123456789abcdef01234567'});
        return const TimerApiResponse(200, {'ok': true});
      }
      return TimerApiResponse(200, {
        'id': 't1',
        'role': 'player',
        'manager': false,
        'status': 'running',
        'startAt': now,
        'endAt': now + 3600 * 1000,
        'config': {'baseSeconds': 3600},
        'history': const [],
        'now': now,
      });
    };
    final service = ChastityTimerService();
    await service.addShared(id: 't1', role: TimerRole.player, key: 'P');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await service.refresh('t1');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(calls.where((c) => c.endsWith('/notify-topic')).length, 1);
    ChastityTimerService.ownTopic = null;
  });
}
