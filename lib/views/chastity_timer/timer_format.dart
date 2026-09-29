import '../../models/chastity_timer.dart';
import '../../models/partner_contact.dart';

/// The day the Chastity Timer reaches everyone, as shown to Patreon users
/// whose partner does not have it yet: 1.1p goes to Patreon on October 1,
/// 2026, the public 1.1.0 on October 14.
final DateTime chastityTimerPublicDate = DateTime(2026, 10, 14);

const String chastityTimerFeature = 'chastityTimer';

String _when() {
  final date = chastityTimerPublicDate;
  const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
      'September', 'October', 'November', 'December'];
  return 'on ${months[date.month - 1]} ${date.day}';
}

/// Shown to a director whose player's copy cannot receive a timer.
String partnerCannotReceiveTimer(PartnerContact partner) =>
    "${partner.displayName} can't use the Chastity Timer yet. It's in early access for "
    'Patreon supporters and reaches everyone ${_when()}. Until then, they can get it now '
    'by installing the Patreon build.';

/// Shown to a player whose director's copy cannot manage a timer.
String partnerCannotManageTimer(PartnerContact partner) =>
    "${partner.displayName} can't manage your timer yet. They'll get the Chastity Timer "
    '${_when()}, or now with the Patreon build. Until then you can run it yourself.';

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
