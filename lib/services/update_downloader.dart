import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'update_service.dart';

/// Why a download ended.
enum UpdateDownloadOutcome {
  ready,

  /// The manifest offers nothing installable for this platform - no file, or
  /// no digest to check it against.
  notOffered,

  /// Never reached the end of the file.
  failed,

  /// Reached the end, but the bytes are not the release that was published.
  digestMismatch,

  cancelled,
}

class UpdateDownloadResult {
  const UpdateDownloadResult(this.outcome, {this.file, this.detail});

  final UpdateDownloadOutcome outcome;

  /// Only set for [UpdateDownloadOutcome.ready]; nothing else leaves a file
  /// behind.
  final File? file;
  final String? detail;

  bool get isReady => outcome == UpdateDownloadOutcome.ready && file != null;
}

/// Bytes of a download in progress, and how many to expect.
class DownloadSource {
  const DownloadSource(this.bytes, {this.contentLength});

  final Stream<List<int>> bytes;
  final int? contentLength;
}

typedef DownloadOpener = Future<DownloadSource> Function(Uri url);

/// Receives the single digest a chunked sha256 conversion produces. Saves
/// pulling in package:convert for its AccumulatorSink, and saves holding a
/// 65MB download in memory to hash it in one go.
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Cooperative cancellation - checked between chunks.
class DownloadCancellation {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// Fetches a published release and proves it is the published release.
///
/// Separate from installing it, which differs per platform, and separate from
/// [UpdateService], which only ever looks. Everything here exists because the
/// file is about to be executed: it is checked against the digest in the
/// manifest, it is only fetched from a host the app already trusts, and it is
/// deleted rather than kept whenever any of that fails.
class UpdateDownloader {
  /// Replaced in tests. The real one streams over HTTPS.
  @visibleForTesting
  static DownloadOpener opener = _openOverHttps;

  static const String fileNamePrefix = 'subtask-update-';

  static Future<UpdateDownloadResult> download({
    required AppUpdate update,
    required Directory into,
    void Function(int received, int? total)? onProgress,
    DownloadCancellation? cancellation,
  }) async {
    final url = update.downloadUrl;
    final expected = update.sha256;

    // No digest means nothing to verify against, and an unverified installer is
    // not worth having. Better to send the user to the release page.
    if (url == null || expected == null) {
      return const UpdateDownloadResult(UpdateDownloadOutcome.notOffered);
    }

    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || !UpdateService.allowedHosts.contains(uri.host)) {
      return const UpdateDownloadResult(
        UpdateDownloadOutcome.notOffered,
        detail: 'download location is not one this app will fetch from',
      );
    }

    final target = File('${into.path}${Platform.pathSeparator}'
        '$fileNamePrefix${update.version}${_extensionOf(uri.path)}');

    IOSink? sink;
    try {
      if (!await into.exists()) await into.create(recursive: true);
      // Any earlier attempt is replaced rather than appended to.
      if (await target.exists()) await target.delete();

      final source = await opener(uri);
      final digest = _DigestSink();
      final hasher = sha256.startChunkedConversion(digest);

      final out = target.openWrite();
      sink = out;
      var received = 0;
      final total = source.contentLength ?? update.sizeBytes;
      onProgress?.call(0, total);

      await for (final chunk in source.bytes) {
        if (cancellation?.isCancelled ?? false) {
          await out.close();
          sink = null;
          await _discard(target);
          return const UpdateDownloadResult(UpdateDownloadOutcome.cancelled);
        }
        out.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }

      await out.flush();
      await out.close();
      sink = null;

      hasher.close();
      final actual = digest.value.toString();
      if (actual != expected) {
        await _discard(target);
        return UpdateDownloadResult(
          UpdateDownloadOutcome.digestMismatch,
          detail: 'expected $expected, got $actual',
        );
      }

      return UpdateDownloadResult(UpdateDownloadOutcome.ready, file: target);
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      await _discard(target);
      if (kDebugMode) print('UpdateDownloader: $e');
      return UpdateDownloadResult(UpdateDownloadOutcome.failed, detail: '$e');
    }
  }

  /// A half-written or unverified file is never left on disk: it would be
  /// indistinguishable from a good one next time.
  static Future<void> _discard(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  static String _extensionOf(String path) {
    for (final ext in ['.apk', '.zip', '.dmg', '.tar.gz']) {
      if (path.toLowerCase().endsWith(ext)) return ext;
    }
    return '';
  }

  static Future<DownloadSource> _openOverHttps(Uri url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    final request = await client.getUrl(url);
    final response = await request.close();
    if (response.statusCode != 200) {
      client.close(force: true);
      throw HttpException('HTTP ${response.statusCode}', uri: url);
    }
    return DownloadSource(
      // Closing the client once the body is done, rather than per chunk.
      response.handleError((Object e) {
        client.close(force: true);
        throw e;
      }).map((chunk) => chunk).transform(
            StreamTransformer<List<int>, List<int>>.fromHandlers(
              handleDone: (out) {
                client.close(force: true);
                out.close();
              },
            ),
          ),
      contentLength: response.contentLength >= 0 ? response.contentLength : null,
    );
  }
}
