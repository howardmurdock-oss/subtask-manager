import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// subtaskmanager:// links: "Open in the app" on a public timer's page, and
/// the check page handing back once a visitor is verified.
///
/// Android passes them through its activity; Windows registers the scheme
/// itself, starts the app with the link as an argument, and hands a link
/// opened while the app runs to the running window (windows/runner).
class AppLinks {
  AppLinks._();

  static final AppLinks instance = AppLinks._();

  static const _channel = MethodChannel('subtask/links');

  final _links = StreamController<Uri>.broadcast();

  /// The link the app was started with, until someone takes it.
  Uri? _pending;

  /// Links opened while the app runs.
  Stream<Uri> get links => _links.stream;

  /// Takes the link the app was started with, if any.
  Uri? takePending() {
    final link = _pending;
    _pending = null;
    return link;
  }

  Future<void> init(List<String> args) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open' && call.arguments is String) {
        final uri = parse(call.arguments as String);
        if (uri != null) _links.add(uri);
      }
      return null;
    });
    for (final arg in args) {
      _pending ??= parse(arg);
    }
    if (_pending == null && defaultTargetPlatform == TargetPlatform.android) {
      try {
        final initial = await _channel.invokeMethod<String>('initial');
        if (initial != null) _pending = parse(initial);
      } catch (_) {}
    }
  }

  /// A subtaskmanager:// link, or null for anything else.
  static Uri? parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    return uri != null && uri.scheme == 'subtaskmanager' ? uri : null;
  }

  /// A public timer or player page a link points at: ('t' or 'p', its id).
  static ({String kind, String id})? publicPageOf(Uri uri) {
    final kind = uri.host;
    final id = uri.pathSegments.isEmpty ? '' : uri.pathSegments.first;
    if ((kind != 't' && kind != 'p') || !RegExp(r'^[A-Za-z0-9_-]{6,32}$').hasMatch(id)) return null;
    return (kind: kind, id: id);
  }
}
