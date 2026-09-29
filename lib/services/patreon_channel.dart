import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/security/patreon_access.dart';
import 'push_service.dart';

/// Early-access builds for Patreon supporters.
///
/// They are published beside the public ones but served by the Worker, which
/// hands them only to a request carrying a valid Patreon code. The repository
/// is public, so the address of these files is no secret; the code is what
/// keeps them to supporters. The Worker checks it against the same digest
/// [PatreonAccess] does.
///
/// That needs the code itself, which the app did not use to keep - only the
/// fact of an unlock. It is kept from now on, and anyone who unlocked before
/// is asked for it once more, in Settings.
class PatreonChannel {
  static const String codeKey = 'patreon_code_v1';

  /// The code travels in this header. Never in the URL: request URLs are
  /// logged, headers are not.
  static const String codeHeader = 'X-Patreon-Code';

  static String get manifestUrl => '${PushService.workerBaseUrl}/patreon/latest.json';
  static String get signatureUrl => '$manifestUrl.sig';

  /// The only host the code is ever sent to.
  static String get host => Uri.parse(PushService.workerBaseUrl).host;

  /// Keeps [code] for fetching early-access builds, if it is valid.
  static Future<void> remember(String code) async {
    if (!PatreonAccess.isValid(code)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(codeKey, code.trim().toUpperCase());
    } catch (_) {}
  }

  static Future<void> forget() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(codeKey);
    } catch (_) {}
  }

  /// The kept code, or null when there is none - or it is no longer one that
  /// unlocks anything, as after the code is changed.
  static Future<String?> storedCode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final code = prefs.getString(codeKey);
      return code != null && PatreonAccess.isValid(code) ? code : null;
    } catch (_) {
      return null;
    }
  }

  /// Swapped out in tests; the real one fetches over HTTPS with the code in
  /// [codeHeader]. Used by UpdateService, so not marked test-only.
  static Future<Uint8List?> Function(Uri url, String code) fetch = _fetchWithCode;

  static Future<Uint8List?> _fetchWithCode(Uri url, String code) async {
    if (url.host != host) return null;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(url).timeout(const Duration(seconds: 10));
      request.headers.set(codeHeader, code);
      final response = await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      // A manifest is a few hundred bytes; anything large is not one.
      if (response.contentLength > 64 * 1024) {
        await response.drain<void>();
        return null;
      }
      final chunks = <int>[];
      await for (final chunk in response) {
        chunks.addAll(chunk);
        if (chunks.length > 64 * 1024) return null;
      }
      return Uint8List.fromList(chunks);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
