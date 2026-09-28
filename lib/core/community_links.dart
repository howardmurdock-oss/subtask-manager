import 'package:url_launcher/url_launcher.dart';

/// The creator's Patreon, where supporters get the access code, and the
/// community Discord. One place, so every button in the app points at the
/// same address.
class CommunityLinks {
  static final Uri patreon = Uri.parse('https://www.patreon.com/cw/TessaMurdock');

  /// A permanent invite: it is set not to expire.
  static final Uri discord = Uri.parse('https://discord.gg/NFTWR4NBGt');

  /// Opens [uri] outside the app: the Patreon or Discord app where one is
  /// installed, the browser otherwise.
  static Future<void> open(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);
}
