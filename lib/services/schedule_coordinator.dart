import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cross-isolate coordination for scheduled order rules.
///
/// The app runs scheduled rules from two places: the UI isolate
/// (`ScheduleService`) and the `flutter_foreground_task` background isolate
/// (`DirectiveSyncTaskHandler`). Each isolate keeps its own in-memory
/// SharedPreferences cache, so without explicit coordination they duplicate
/// each other's work and overwrite each other's writes.
///
/// Two primitives solve that:
///
///  * **Occurrence ledger** — every rule execution is claimed under a key of
///    `<ruleId>@<triggerTimestamp>` before any work happens. A claim is atomic
///    within an isolate and reload-checked across isolates, so a given rule
///    occurrence fires exactly once no matter who gets there first.
///  * **Foreground heartbeat** — the UI isolate stamps a timestamp while it is
///    resumed. The background isolate defers rule execution while that stamp is
///    fresh, so the two are not racing in the common case and the ledger only
///    has to catch the edges.
class ScheduleCoordinator {
  static const String ledgerKey = 'scheduled_occurrence_ledger_v1';
  static const String heartbeatKey = 'app_foreground_heartbeat_ms_v1';

  /// Occurrences retained before the oldest entries are trimmed. Generous
  /// enough that a rule cannot be re-fired after a long sleep, small enough
  /// that the list stays cheap to encode on every claim.
  static const int maxLedgerEntries = 400;

  /// How long a foreground heartbeat is considered fresh.
  static const Duration heartbeatTtl = Duration(seconds: 90);

  /// Stable identity for a single firing of a rule.
  ///
  /// Truncated to whole minutes so that a trigger time which round-trips
  /// through JSON with differing sub-second precision still resolves to the
  /// same occurrence.
  static String occurrenceKey(String ruleId, DateTime triggerTime) {
    final t = triggerTime.toUtc();
    final stamp = '${t.year.toString().padLeft(4, '0')}'
        '${t.month.toString().padLeft(2, '0')}'
        '${t.day.toString().padLeft(2, '0')}'
        'T${t.hour.toString().padLeft(2, '0')}'
        '${t.minute.toString().padLeft(2, '0')}';
    return '$ruleId@$stamp';
  }

  /// Deterministic active-order id for one firing of a rule.
  ///
  /// Both isolates derive the same id for the same occurrence, so if an order
  /// ever reaches `OrderEngine` twice — background hand-off plus a UI-isolate
  /// catch-up, say — it is recognised as the same order and mounted once.
  /// Conversely two *different* rules firing the same underlying task get
  /// different ids and both mount, which title-based matching could not do.
  static String activeOrderIdFor(String ruleId, DateTime triggerTime) =>
      'sched_${occurrenceKey(ruleId, triggerTime)}';

  static Future<List<String>> loadLedger(SharedPreferences prefs) async {
    try {
      await prefs.reload();
    } catch (_) {}
    return prefs.getStringList(ledgerKey) ?? const <String>[];
  }

  /// Claims [key] for execution, returning `true` only for the caller that wins.
  ///
  /// The claim is written before the caller does any work, so a crash mid-
  /// execution loses that occurrence rather than replaying it forever.
  static Future<bool> claimOccurrence(
    SharedPreferences prefs,
    String key,
  ) async {
    try {
      final ledger = List<String>.from(await loadLedger(prefs));
      if (ledger.contains(key)) return false;
      ledger.add(key);
      if (ledger.length > maxLedgerEntries) {
        ledger.removeRange(0, ledger.length - maxLedgerEntries);
      }
      await prefs.setStringList(ledgerKey, ledger);
      return true;
    } catch (e) {
      if (kDebugMode) print('ScheduleCoordinator.claimOccurrence error: $e');
      // Fail open: a missed order is worse than a duplicated one.
      return true;
    }
  }

  /// Records occurrences the caller has already executed (used by the UI
  /// isolate, which claims synchronously against its in-memory mirror and then
  /// persists in the background).
  static Future<void> recordOccurrences(
    SharedPreferences prefs,
    Iterable<String> keys,
  ) async {
    if (keys.isEmpty) return;
    try {
      final ledger = List<String>.from(await loadLedger(prefs));
      var changed = false;
      for (final key in keys) {
        if (!ledger.contains(key)) {
          ledger.add(key);
          changed = true;
        }
      }
      if (!changed) return;
      if (ledger.length > maxLedgerEntries) {
        ledger.removeRange(0, ledger.length - maxLedgerEntries);
      }
      await prefs.setStringList(ledgerKey, ledger);
    } catch (e) {
      if (kDebugMode) print('ScheduleCoordinator.recordOccurrences error: $e');
    }
  }

  static Future<void> markForegroundAlive(SharedPreferences prefs) async {
    try {
      await prefs.setInt(heartbeatKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  static Future<void> clearForegroundAlive(SharedPreferences prefs) async {
    try {
      await prefs.remove(heartbeatKey);
    } catch (_) {}
  }

  /// Whether the UI isolate stamped a heartbeat recently enough that it should
  /// be left to run due rules itself.
  static Future<bool> isForegroundAlive(SharedPreferences prefs) async {
    try {
      await prefs.reload();
      final ms = prefs.getInt(heartbeatKey);
      if (ms == null) return false;
      final age = DateTime.now().millisecondsSinceEpoch - ms;
      return age >= 0 && age < heartbeatTtl.inMilliseconds;
    } catch (_) {
      return false;
    }
  }
}
