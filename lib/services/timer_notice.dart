import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/notifications/notification_service.dart';
import '../models/chastity_timer.dart';
import '../models/sync_message.dart';
import '../views/chastity_timer/timer_format.dart';
import 'chastity_timer_service.dart';

/// Tells a timer's person what changed on it - once, from whichever path a
/// `timerChanged` message reaches first: the app, a push woken in the
/// background, or the background link. Each of them calls [announce].
///
/// Two kinds arrive. A partner's own change carries its words, already
/// written by their app and sent over the encrypted channel. The Worker's
/// wake-up for public additions carries only the timer's id: what was added
/// is fetched here with this device's key, so a forged wake-up announces
/// nothing that did not happen.
class TimerNotice {
  TimerNotice._();

  /// Messages already announced, so a second path stays quiet.
  static const String announcedKey = 'chastity_timer_notices_v1';

  /// Per timer, the time of the last public addition announced.
  static const String publicSeenKey = 'chastity_timer_public_seen_v1';

  static const String title = 'Chastity Timer';

  /// Announces [msg], unless another path already has. Returns whether a
  /// notification was shown.
  static Future<bool> announce(SyncMessage msg) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      if (msg.id.isNotEmpty && !await _claim(prefs, msg.id)) return false;

      final timerId = msg.payload['timerId'] as String?;
      if (timerId == null) return false;

      if (msg.payload['check'] == 'public') return await _announcePublic(prefs, timerId);

      final summary = msg.payload['summary'] as String?;
      if (summary == null || summary.isEmpty) return false;
      final senderName = msg.payload['senderName'] as String?;
      await NotificationService.showGenericNotification(
        // A notice is a whole sentence of its own, saying who.
        title: msg.payload['notice'] == true || senderName == null || senderName.isEmpty
            ? title
            : 'Timer updated by $senderName',
        body: summary,
      );
      return true;
    } catch (e) {
      if (kDebugMode) print('TimerNotice.announce error: $e');
      return false;
    }
  }

  /// Starts counting public additions from now, so ones from before this
  /// device was listening are not announced as new.
  static Future<void> startCounting(String timerId, DateTime serverNow) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final seen = _seenMap(prefs);
      if (seen.containsKey(timerId)) return;
      seen[timerId] = serverNow.millisecondsSinceEpoch;
      await prefs.setString(publicSeenKey, jsonEncode(seen));
    } catch (_) {}
  }

  static Future<bool> _announcePublic(SharedPreferences prefs, String timerId) async {
    final record = _recordOf(prefs, timerId);
    if (record == null || record.role != TimerRole.player) return false;
    final response = await ChastityTimerService.fetchView(timerId, record.key);
    if (!response.ok) return false;
    final view = ChastityTimerView.fromJson(response.body);

    final seen = _seenMap(prefs);
    final since = seen[timerId];
    final added = view.history
        .where((e) => e.actor == TimerActor.public)
        .where((e) => since == null || e.at.millisecondsSinceEpoch > since)
        .where((e) => e.deltaSeconds == null || e.deltaSeconds! > 0)
        .toList();
    seen[timerId] = [
      since ?? 0,
      view.serverNow.millisecondsSinceEpoch,
      ...added.map((e) => e.at.millisecondsSinceEpoch),
    ].reduce((a, b) => a > b ? a : b);
    await prefs.setString(publicSeenKey, jsonEncode(seen));
    // Not counting yet: nothing from before can be told apart from now.
    if (since == null || added.isEmpty || !view.config.notifyOnAdd) return false;

    final String body;
    if (added.any((e) => e.deltaSeconds == null)) {
      // A hidden timer: the amounts are not this device's to know - nor,
      // where the public may also remove time, which way it went.
      body = view.config.publicLink.allowRemove
          ? 'Your timer was changed by the public.'
          : addedNotice(message: view.config.notifyMessage, by: TimerActor.public);
    } else {
      final total = added.fold<int>(0, (sum, e) => sum + e.deltaSeconds!);
      body = addedNotice(
          message: view.config.notifyMessage, amount: Duration(seconds: total), by: TimerActor.public);
    }
    await NotificationService.showGenericNotification(title: title, body: body);
    return true;
  }

  static TimerRecord? _recordOf(SharedPreferences prefs, String id) {
    final raw = prefs.getString(ChastityTimerService.recordsKey);
    if (raw == null) return null;
    for (final m in (jsonDecode(raw) as List).whereType<Map>()) {
      final r = TimerRecord.fromJson(Map<String, dynamic>.from(m));
      if (r.id == id) return r;
    }
    return null;
  }

  static Map<String, int> _seenMap(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(publicSeenKey);
      if (raw == null) return {};
      return (jsonDecode(raw) as Map).map((k, v) => MapEntry(k as String, (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  static Future<bool> _claim(SharedPreferences prefs, String id) async {
    final ids = List<String>.from(prefs.getStringList(announcedKey) ?? const <String>[]);
    if (ids.contains(id)) return false;
    ids.add(id);
    if (ids.length > 200) ids.removeRange(0, ids.length - 200);
    await prefs.setStringList(announcedKey, ids);
    return true;
  }
}
