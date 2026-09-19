import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/core/notifications/notification_service.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/scheduled_order_rule.dart';
import 'package:orders_app/services/schedule_service.dart';

/// The Worker deletes each staged row as it fires it and cannot mint a
/// replacement - the payload is ciphertext it is never able to read. So the
/// staged horizon is the entire margin between a working schedule and one that
/// stops dead, silently, with every rule still showing as enabled.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  OrderItem task(String id) => OrderItem(
        id: id,
        title: 'Task $id',
        description: 'Do the thing',
        category: 'Discipline',
        tier: 1,
        rewardTokens: 10,
      );

  ScheduledOrderRule dailySelfDraw({
    required String id,
    required int hour,
    bool isEnabled = true,
  }) =>
      ScheduledOrderRule(
        id: id,
        title: 'Daily $hour',
        targetType: ScheduleTargetType.playerSelfDraw,
        timingMode: ScheduleTimingMode.randomWindow,
        frequency: RepeatFrequency.daily,
        windowStartHour: hour,
        windowStartMinute: 0,
        windowEndHour: hour,
        windowEndMinute: 15,
        stagedOrder: task('ord_$id'),
        isEnabled: isEnabled,
      );

  List<Map<String, dynamic>> build(List<ScheduledOrderRule> rules) =>
      ScheduleService.buildStagedEntries(
        rules: rules,
        myCode: 'PLAYER1',
        mySecret: 'SHARED_SECRET',
        from: DateTime(2026, 9, 13, 12),
      );

  test('stages far enough ahead to survive the app not being opened', () {
    final entries = build([dailySelfDraw(id: 'r1', hour: 9)]);

    expect(entries.length, ScheduleService.stagedOccurrences);
    // The alarm slot count is bounded by what the OS will hold; the staged
    // horizon is not, and tying the two together is what left a five-day cliff.
    expect(
      ScheduleService.stagedOccurrences,
      greaterThan(NotificationService.preArmedOccurrences),
    );

    final last = DateTime.fromMillisecondsSinceEpoch(entries.last['at'] as int);
    expect(last.difference(DateTime(2026, 9, 13, 12)).inDays, greaterThanOrEqualTo(12));
  });

  test('interleaves rules nearest-first so a cap cannot starve one of them', () {
    final entries = build([
      dailySelfDraw(id: 'r1', hour: 9),
      dailySelfDraw(id: 'r2', hour: 21),
    ]);

    final times = entries.map((e) => e['at'] as int).toList();
    expect(times, orderedEquals(List<int>.from(times)..sort()));

    // Truncating the tail - which is what the Worker does past its per-topic
    // cap - must leave both rules represented, not all of one and none of the
    // other.
    final survivors = entries.take(10).map((e) => (e['ruleId'] as String).split('_').first);
    expect(survivors.toSet(), {'r1', 'r2'});
  });

  test('stages only enabled self-draw rules', () {
    final entries = build([
      dailySelfDraw(id: 'r1', hour: 9),
      dailySelfDraw(id: 'off', hour: 10, isEnabled: false),
      ScheduledOrderRule(
        id: 'dir',
        title: 'Director rule',
        targetType: ScheduleTargetType.directorDispatch,
        timingMode: ScheduleTimingMode.randomWindow,
        frequency: RepeatFrequency.daily,
        windowStartHour: 11,
        windowStartMinute: 0,
        windowEndHour: 11,
        windowEndMinute: 15,
        stagedOrder: task('ord_dir'),
      ),
    ]);

    final ruleIds =
        entries.map((e) => (e['ruleId'] as String).split('_').first).toSet();
    expect(ruleIds, {'r1'});
  });

  test('re-staging a random window does not reshuffle it', () {
    // Every computation used to re-roll each future day, so the local alarm,
    // the server row and the next re-stage all disagreed about when the same
    // occurrence was - and dedup, which keys on that time, could never match
    // them up.
    final rule = dailySelfDraw(id: 'r1', hour: 9);
    final first = build([rule]).map((e) => e['at']).toList();
    final second = build([rule]).map((e) => e['at']).toList();
    expect(second, orderedEquals(first));

    final from = DateTime(2026, 9, 13, 12);
    expect(rule.upcomingTriggers(ScheduleService.stagedOccurrences, from: from),
        orderedEquals(rule.upcomingTriggers(ScheduleService.stagedOccurrences, from: from)));
  });

  test('a stable random window still lands inside the window, and varies', () {
    final rule = dailySelfDraw(id: 'r1', hour: 9);
    final triggers = rule.upcomingTriggers(14, from: DateTime(2026, 9, 13, 12));

    for (final t in triggers) {
      expect(t.hour, 9);
      expect(t.minute, lessThan(15));
    }
    // Stable per day, but not the same minute every day - it is still random
    // from the user's point of view.
    expect(triggers.map((t) => t.minute * 60 + t.second).toSet().length, greaterThan(1));

    // Two rules with the same window do not fire in lockstep.
    final other = dailySelfDraw(id: 'r2', hour: 9)
        .upcomingTriggers(14, from: DateTime(2026, 9, 13, 12));
    expect(other, isNot(orderedEquals(triggers)));
  });
}
