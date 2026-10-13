import '../../models/chastity_timer.dart';
import '../../models/partner_contact.dart';

const String chastityTimerFeature = 'chastityTimer';

/// Shown to a director whose player's copy cannot receive a timer.
String partnerCannotReceiveTimer(PartnerContact partner) =>
    "${partner.displayName} can't use the Chastity Timer yet. "
    'They need to update to SubTask Manager 1.1.0 or newer.';

/// Shown to a player whose director's copy cannot manage a timer.
String partnerCannotManageTimer(PartnerContact partner) =>
    "${partner.displayName} can't manage your timer yet. "
    'They need to update to SubTask Manager 1.1.0 or newer. Until then you can run it yourself.';

/// "2d 04:15:09" style, for a live countdown.
String formatCountdown(Duration d) {
  final s = d.isNegative ? 0 : d.inSeconds;
  final days = s ~/ 86400;
  String two(int n) => n.toString().padLeft(2, '0');
  final clock = '${two(s % 86400 ~/ 3600)}:${two(s % 3600 ~/ 60)}:${two(s % 60)}';
  return days > 0 ? '${days}d $clock' : clock;
}

/// "3 days 4 hours", "45 minutes" - for amounts and settings.
String formatSpan(Duration d) {
  final total = d.inMinutes.abs();
  if (total == 0) return '${d.inSeconds.abs()} seconds';
  final days = total ~/ 1440, hours = total % 1440 ~/ 60, minutes = total % 60;
  final parts = <String>[
    if (days > 0) '$days ${days == 1 ? 'day' : 'days'}',
    if (hours > 0) '$hours ${hours == 1 ? 'hour' : 'hours'}',
    if (minutes > 0) '$minutes ${minutes == 1 ? 'minute' : 'minutes'}',
  ];
  return parts.join(' ');
}

/// "+1 hour" / "−30 minutes".
String formatChange(int seconds) =>
    '${seconds >= 0 ? '+' : '−'}${formatSpan(Duration(seconds: seconds))}';

String actorLabel(TimerActor actor, {String? partnerName, required TimerRole viewer}) {
  switch (actor) {
    case TimerActor.player:
      return viewer == TimerRole.player ? 'You' : (partnerName ?? 'Player');
    case TimerActor.director:
      return viewer == TimerRole.director ? 'You' : (partnerName ?? 'Director');
    case TimerActor.random:
      return 'Random';
    case TimerActor.public:
      return 'Public vote';
  }
}

/// Longest custom notification message; the Worker keeps the same limit.
const int noticeMessageMax = 120;

/// What the player is told when time is added: the manager's own words, or
/// plain ones - always saying who added it. "{time}" in the message is
/// replaced by the amount.
String addedNotice({String? message, Duration? amount, required TimerActor by}) {
  final who = switch (by) {
    TimerActor.director => 'your Director',
    TimerActor.public => 'the public',
    TimerActor.player => 'you',
    TimerActor.random => 'chance',
  };
  final time = amount == null ? null : formatSpan(amount);
  final own = message?.trim() ?? '';
  if (own.isEmpty) {
    return time == null ? 'Time was added by $who.' : '$time was added by $who.';
  }
  var text = own.replaceAll('{time}', time ?? 'some time');
  text = text.replaceFirst(RegExp(r'[\s.,;:]+$'), '');
  if (text.isNotEmpty) text = text[0].toUpperCase() + text.substring(1);
  // "...Toy!" reads better followed by a sentence than by a comma.
  return RegExp(r'[!?]$').hasMatch(text) ? '$text Added by $who.' : '$text, added by $who.';
}
