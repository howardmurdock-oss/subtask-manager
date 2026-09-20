import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'schedule_service.dart';

/// A newer release, as described by the published manifest.
class AppUpdate {
  const AppUpdate({
    required this.version,
    this.released,
    this.notesUrl,
    this.downloadUrl,
    this.sizeBytes,
  });

  final String version;
  final String? released;
  final String? notesUrl;

  /// Null when the manifest offers nothing for this platform, or offers a link
  /// somewhere we are not willing to send people.
  final String? downloadUrl;
  final int? sizeBytes;

  String? get sizeLabel =>
      sizeBytes == null ? null : '${(sizeBytes! / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Checks whether a newer version has been published.
///
/// The app is distributed outside any store, so nothing tells a user they are
/// running an old build - testers have sat on versions months apart without
/// knowing. This reads a small manifest published with each release and says
/// so. It downloads and installs nothing.
class UpdateService {
  static const String manifestUrl = 'https://subtaskmanager.com/latest.json';

  static const String lastCheckedKey = 'update_last_checked_v1';
  static const String skippedVersionKey = 'update_skipped_version_v1';

  /// Long enough that launching the app repeatedly costs nothing, short enough
  /// that a release is noticed the next day.
  static const Duration checkInterval = Duration(hours: 20);

  /// Where a download link may point. The manifest is fetched over HTTPS from
  /// our own site, but it is still data from the network deciding where to
  /// send someone - so the destination is checked rather than trusted.
  static const Set<String> allowedHosts = {
    'subtaskmanager.com',
    'www.subtaskmanager.com',
    'github.com',
    'objects.githubusercontent.com',
  };

  /// Kept in step with pubspec by the release script, which rewrites it.
  static String get currentVersion => ScheduleService.appCurrentBuildVersion;

  /// Web is served fresh on every load, so there is nothing to tell the user.
  static bool get isSupported => !kIsWeb;

  static String get platformKey {
    if (kIsWeb) return 'web';
    if (Platform.isWindows) return 'windows';
    if (Platform.isAndroid) return 'android';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  /// Swapped out in tests; the real one fetches over HTTPS.
  @visibleForTesting
  static Future<String?> Function(Uri url) fetch = _fetchOverHttps;

  /// Negative when [a] is older than [b]. Missing components count as zero, so
  /// "1.4" and "1.4.0" are the same version.
  @visibleForTesting
  static int compareVersions(String a, String b) {
    List<int> parts(String v) => v
        .trim()
        .split(RegExp(r'[.+\-]'))
        .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();

    final left = parts(a);
    final right = parts(b);
    for (var i = 0; i < (left.length > right.length ? left.length : right.length); i++) {
      final l = i < left.length ? left[i] : 0;
      final r = i < right.length ? right[i] : 0;
      if (l != r) return l.compareTo(r);
    }
    return 0;
  }

  static bool isNewer(String candidate, String current) =>
      compareVersions(candidate, current) > 0;

  static String? _safeUrl(Object? value) {
    if (value is! String || value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https') return null;
    return allowedHosts.contains(uri.host) ? value : null;
  }

  /// Returns the update described by [body], or null when it is not newer,
  /// not for this platform, or not something we can make sense of.
  @visibleForTesting
  static AppUpdate? parseManifest(
    String body, {
    required String currentVersion,
    required String platformKey,
  }) {
    try {
      // A byte-order mark is invisible and fatal to jsonDecode. Tools on the
      // publishing side add one without being asked.
      final data = jsonDecode(body.replaceFirst(RegExp(r'^﻿'), '').trim());
      if (data is! Map) return null;

      final version = data['version'];
      if (version is! String || version.trim().isEmpty) return null;
      if (!isNewer(version, currentVersion)) return null;

      final downloads = data['downloads'];
      final forPlatform =
          downloads is Map ? downloads[platformKey] : null;

      return AppUpdate(
        version: version.trim(),
        released: data['released'] is String ? data['released'] as String : null,
        notesUrl: _safeUrl(data['notesUrl']),
        downloadUrl: forPlatform is Map ? _safeUrl(forPlatform['url']) : null,
        sizeBytes: forPlatform is Map ? (forPlatform['size'] as num?)?.toInt() : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// The newer version, or null. Never throws: a failed check is silent, since
  /// there is nothing the user could do about it.
  static Future<AppUpdate?> check({bool force = false}) async {
    if (!isSupported) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      if (!force) {
        final last = DateTime.tryParse(prefs.getString(lastCheckedKey) ?? '');
        if (last != null && DateTime.now().difference(last) < checkInterval) {
          return null;
        }
      }

      final body = await fetch(Uri.parse(manifestUrl));
      await prefs.setString(lastCheckedKey, DateTime.now().toIso8601String());
      if (body == null) return null;

      // Deliberately not filtered by [skip] here: that decides whether to
      // interrupt someone, not whether an update exists. A user who asks
      // outright should be told about a version they waved away earlier.
      return parseManifest(
        body,
        currentVersion: currentVersion,
        platformKey: platformKey,
      );
    } catch (e) {
      if (kDebugMode) print('UpdateService.check error: $e');
      return null;
    }
  }

  /// Whether the user has waved this version away. Checked before interrupting
  /// them with it; an update they asked about is shown regardless.
  static Future<bool> isSkipped(String version) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return prefs.getString(skippedVersionKey) == version;
    } catch (_) {
      return false;
    }
  }

  static Future<void> skip(String version) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(skippedVersionKey, version);
    } catch (_) {}
  }

  static Future<String?> _fetchOverHttps(Uri url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(url).timeout(const Duration(seconds: 10));
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
      return await response.transform(utf8.decoder).join();
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
