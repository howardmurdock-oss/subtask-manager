import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/scheduled_order_rule.dart';

/// A Patreon supporter's features extend to the directors who play with them.
///
/// A player whose copy is unlocked says so to their partners (the
/// "patreonSupporter" feature in SyncService's feature announcement). A
/// director without the code of their own may then use Quests and Scheduled
/// Orders with that player - and only with that player: it opens nothing for
/// anyone else, or for the director's own use.
///
/// When the player's access stops being announced, the director's scheduled
/// orders for them pause - skipped, not queued - and resume once it is back.
/// Quests already under way are left to finish. Nothing new can be set up.
///
/// Kept free of the app's services: the background isolate, which fires rules
/// while the app is closed, has none of them - only SharedPreferences.
class PatreonSponsorship {
  /// The feature a supporter's copy announces.
  static const String supporterFeature = 'patreonSupporter';

  /// This device's own unlock (shared by Quests and Scheduled Orders).
  static const String unlockKey = 'patreon_vip_unlocked_v1';

  /// Written by SyncService: partner pairing code -> announced features.
  static const String partnerFeaturesKey = 'partner_features_v1';

  static String _normalize(String code) => code.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();

  /// Whether this device has unlocked the Patreon features itself.
  static bool ownUnlock(SharedPreferences prefs) => prefs.getBool(unlockKey) ?? false;

  /// Whether the partner with [pairingCode] has announced Patreon support.
  static bool partnerIsSupporter(SharedPreferences prefs, String? pairingCode) {
    final code = _normalize(pairingCode ?? '');
    if (code.isEmpty) return false;
    try {
      final raw = prefs.getString(partnerFeaturesKey);
      if (raw == null) return false;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final features = map[code];
      return features is List && features.contains(supporterFeature);
    } catch (_) {
      return false;
    }
  }

  /// Whether [rule] must not fire now: a director's rule for a partner, set
  /// up without this device's own unlock, whose partner's support is not
  /// currently announced. Rules for "Myself", player self-draws, and anything
  /// on an unlocked device always fire.
  static bool isPaused(ScheduledOrderRule rule, SharedPreferences prefs) {
    if (rule.targetType != ScheduleTargetType.directorDispatch) return false;
    final code = rule.targetPartnerCode;
    final isSelf = rule.targetPartnerId == '__self__' ||
        rule.targetPartnerName == 'Myself (This Device)' ||
        code == null ||
        code.isEmpty;
    if (isSelf) return false;
    if (ownUnlock(prefs)) return false;
    return !partnerIsSupporter(prefs, code);
  }
}
