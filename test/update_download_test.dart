import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/services/update_downloader.dart';
import 'package:orders_app/services/update_service.dart';

/// This decides what the app is about to execute, so every way it can go wrong
/// matters more than the way it goes right: a file that does not match the
/// published digest, a download that stops halfway, a link pointing somewhere
/// other than where releases live.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workDir;

  final payload = utf8.encode('pretend this is an installer' * 64);
  final payloadDigest = sha256.convert(payload).toString();

  const goodUrl =
      'https://github.com/howardmurdock-oss/subtask-manager/releases/latest/download/subTaskManager-Android-Release.apk';

  AppUpdate update({String? url = goodUrl, String? digest, int? size}) => AppUpdate(
        version: '9.9.9',
        downloadUrl: url,
        sha256: digest ?? payloadDigest,
        sizeBytes: size ?? payload.length,
      );

  /// Serves [chunks], optionally failing partway through.
  void serve(List<List<int>> chunks, {Object? failAfterChunks}) {
    UpdateDownloader.opener = (_) async => DownloadSource(
          () async* {
            var sent = 0;
            for (final chunk in chunks) {
              if (failAfterChunks == sent) throw const SocketException('connection lost');
              yield chunk;
              sent++;
            }
            if (failAfterChunks == sent) throw const SocketException('connection lost');
          }(),
          contentLength: chunks.fold<int>(0, (sum, c) => sum + c.length),
        );
  }

  List<List<int>> inChunks(List<int> bytes, int count) {
    final size = (bytes.length / count).ceil();
    return [
      for (var i = 0; i < bytes.length; i += size)
        bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size),
    ];
  }

  setUp(() async {
    workDir = await Directory.systemTemp.createTemp('update_download_test');
  });

  tearDown(() async {
    UpdateDownloader.opener = (_) async => throw StateError('not stubbed');
    if (await workDir.exists()) await workDir.delete(recursive: true);
  });

  Future<List<FileSystemEntity>> leftovers() => workDir.list().toList();

  test('a matching download is kept, and progress is reported', () async {
    serve(inChunks(payload, 4));
    final seen = <int>[];

    final result = await UpdateDownloader.download(
      update: update(),
      into: workDir,
      onProgress: (received, total) {
        seen.add(received);
        expect(total, payload.length);
      },
    );

    expect(result.isReady, isTrue);
    expect(await result.file!.readAsBytes(), payload);
    expect(seen.first, 0);
    expect(seen.last, payload.length);
    expect(seen, seen.toList()..sort(), reason: 'progress should only go forwards');
  });

  test('a file that is not the published release is deleted, not installed', () async {
    serve(inChunks(utf8.encode('something else entirely'), 2));

    final result = await UpdateDownloader.download(update: update(), into: workDir);

    expect(result.outcome, UpdateDownloadOutcome.digestMismatch);
    expect(result.file, isNull);
    expect(await leftovers(), isEmpty,
        reason: 'a rejected file left on disk is indistinguishable from a good one next time');
  });

  test('a download that stops partway leaves nothing behind', () async {
    serve(inChunks(payload, 4), failAfterChunks: 2);

    final result = await UpdateDownloader.download(update: update(), into: workDir);

    expect(result.outcome, UpdateDownloadOutcome.failed);
    expect(await leftovers(), isEmpty);
  });

  test('cancelling stops the download and removes the partial file', () async {
    final cancellation = DownloadCancellation();
    serve(inChunks(payload, 8));

    final result = await UpdateDownloader.download(
      update: update(),
      into: workDir,
      cancellation: cancellation,
      onProgress: (received, _) {
        if (received > 0) cancellation.cancel();
      },
    );

    expect(result.outcome, UpdateDownloadOutcome.cancelled);
    expect(await leftovers(), isEmpty);
  });

  test('without a published digest, nothing is downloaded at all', () async {
    var opened = false;
    UpdateDownloader.opener = (_) async {
      opened = true;
      return DownloadSource(Stream.value(payload));
    };

    final result = await UpdateDownloader.download(
      update: AppUpdate(version: '9.9.9', downloadUrl: goodUrl),
      into: workDir,
    );

    expect(result.outcome, UpdateDownloadOutcome.notOffered);
    expect(opened, isFalse, reason: 'there would be nothing to check the bytes against');
  });

  test('a link pointing somewhere other than a release host is refused', () async {
    var opened = false;
    UpdateDownloader.opener = (_) async {
      opened = true;
      return DownloadSource(Stream.value(payload));
    };

    for (final url in [
      'https://evil.example.com/app.apk',
      'http://github.com/howardmurdock-oss/subtask-manager/app.apk',
    ]) {
      final result = await UpdateDownloader.download(update: update(url: url), into: workDir);
      expect(result.outcome, UpdateDownloadOutcome.notOffered, reason: url);
    }
    expect(opened, isFalse);
  });

  test('a previous attempt is replaced rather than appended to', () async {
    final stale = File('${workDir.path}${Platform.pathSeparator}'
        '${UpdateDownloader.fileNamePrefix}9.9.9.apk');
    await stale.writeAsBytes(utf8.encode('half of an older attempt'));

    serve(inChunks(payload, 3));
    final result = await UpdateDownloader.download(update: update(), into: workDir);

    expect(result.isReady, isTrue);
    expect(await result.file!.readAsBytes(), payload);
  });
}
