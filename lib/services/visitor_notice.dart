import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/notifications/notification_service.dart';
import '../models/sync_message.dart';
import 'public_visitor_service.dart';

/// Tells this app's person about someone else's public timer: an order they
/// sent from the app (its proof is ready to check, or it is settled), or a
/// timer they watch has ended. The Worker's message only names the public
/// link; what happened is read from the public page, so a forged message
/// announces nothing that did not happen. Once per event, from whichever path
/// gets it first.
class VisitorNotice {
  VisitorNotice._();

  static const String announcedKey = 'public_visitor_notices_v1';

  /// Whether [msg] is one of these: from the Worker, naming a public link.
  static bool isFor(SyncMessage msg) => msg.senderId == 'timer-service' && msg.payload['publicId'] is String;

  static Future<bool> announce(SyncMessage msg) async {
    try {
      final publicId = msg.payload['publicId'] as String?;
      if (publicId == null) return false;
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      switch (msg.payload['check']) {
        case 'issued':
          return await _issued(prefs, publicId, msg.payload['no']);
        case 'ended':
          if (!await _claim(prefs, 'ended-$publicId')) return false;
          await NotificationService.showGenericNotification(
            title: 'A timer you watch has ended',
            body: 'Open the app to see how it went.',
          );
          return true;
      }
    } catch (e) {
      if (kDebugMode) print('VisitorNotice.announce error: $e');
    }
    return false;
  }

  static Future<bool> _issued(SharedPreferences prefs, String publicId, Object? no) async {
    if (no is! num) return false;
    final page = await PublicVisitorService.fetchTimerState(publicId);
    if (!page.ok) return false;
    final orders = page.body['orders'];
    final feed = orders is Map ? (orders['feed'] as List? ?? const []) : const [];
    final entry = feed.whereType<Map>().where((f) => f['no'] == no.toInt()).firstOrNull;
    if (entry == null) return false;
    final status = entry['status'] as String? ?? '';
    final title = entry['title'] as String? ?? 'Your order';
    final text = switch (status) {
      'reviewing' => entry['hasProof'] == true ? 'Proof is ready - open the timer to approve or reject it.' : null,
      'completed' => entry['auto'] == true ? 'Done - approved as it was not checked in time.' : 'Done.',
      'failed' => 'Not done: it counts as failed.',
      'skipped' => 'Skipped.',
      'expired' => 'They ran out of time.',
      _ => null,
    };
    if (text == null || !await _claim(prefs, 'issued-$publicId-${no.toInt()}-$status')) return false;
    await NotificationService.showGenericNotification(title: 'Your order: $title', body: text);
    return true;
  }

  static Future<bool> _claim(SharedPreferences prefs, String key) async {
    final done = List<String>.from(prefs.getStringList(announcedKey) ?? const <String>[]);
    if (done.contains(key)) return false;
    done.add(key);
    if (done.length > 200) done.removeRange(0, done.length - 200);
    await prefs.setStringList(announcedKey, done);
    return true;
  }
}
