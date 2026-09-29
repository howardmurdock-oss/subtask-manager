import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/notifications/notification_service.dart';
import '../models/chastity_timer.dart';
import 'push_service.dart';

/// A reply from the Worker: its status and decoded JSON body.
class TimerApiResponse {
  const TimerApiResponse(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;
  bool get ok => status >= 200 && status < 300;

  /// The Worker's reason for refusing a change, e.g. 'daily-cap'.
  String? get error => body['error'] as String?;
}

/// Why a timer action did not happen, in words for the person who tried it.
String describeTimerError(String? code) {
  switch (code) {
    case 'daily-cap':
      return "That would go over today's limit for changes.";
    case 'not-allowed':
      return "That isn't allowed on this timer.";
    case 'not-running':
      return 'This timer has already finished.';
    case 'too-many-changes':
      return 'This timer has had as many changes as it can take.';
    case 'bad-amount':
      return "That amount can't be used.";
    case 'not your timer':
      return "This device doesn't have access to that timer any more.";
    case 'no such timer':
      return 'That timer no longer exists.';
    case 'offline':
      return "Couldn't reach the timer. Check your connection.";
    default:
      return "That didn't work. Try again in a moment.";
  }
}

/// This device's chastity timers: the records of which ones it can reach,
/// and the latest view of each from the Worker.
///
/// The Worker is the only place a timer's end is worked out. This keeps
/// nothing but ids and keys on the device, asks for a fresh view when one is
/// wanted, and arms a local notification for the end it was last told about.
class ChastityTimerService extends ChangeNotifier {
  ChastityTimerService();

  static const String recordsKey = 'chastity_timer_records_v1';

  /// Where the public link page is served (a route on the website's domain).
  static const String publicLinkBase = 'https://subtaskmanager.com/t/';

  static String get apiBase => '${PushService.workerBaseUrl}/timer';

  /// Swapped out in tests; the real one talks to the Worker over HTTPS.
  @visibleForTesting
  static Future<TimerApiResponse> Function(String method, Uri url, {String? key, Object? body}) request =
      _requestOverHttps;

  final List<TimerRecord> _records = [];
  final Map<String, ChastityTimerView> _views = {};
  bool _loaded = false;

  List<TimerRecord> get records => List.unmodifiable(_records);
  ChastityTimerView? viewOf(String id) => _views[id];
  bool get isLoaded => _loaded;

  /// Timers not yet over, most recent first, for this device's [role].
  List<TimerRecord> active({TimerRole? role}) => _records
      .where((r) => role == null || r.role == role)
      .where((r) => !(_views[r.id]?.isOver ?? false))
      .toList()
    ..sort((a, b) => b.addedAt.compareTo(a.addedAt));

  static String publicLinkFor(String publicId) => '$publicLinkBase$publicId';

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(recordsKey);
      _records
        ..clear()
        ..addAll(raw == null
            ? const []
            : (jsonDecode(raw) as List)
                .whereType<Map>()
                .map((m) => TimerRecord.fromJson(Map<String, dynamic>.from(m))));
    } catch (e) {
      if (kDebugMode) print('ChastityTimerService: load error: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(recordsKey, jsonEncode(_records.map((r) => r.toJson()).toList()));
    } catch (e) {
      if (kDebugMode) print('ChastityTimerService: save error: $e');
    }
  }

  TimerRecord? recordOf(String id) {
    for (final r in _records) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// Sets up a new timer, managed by this device in [role]. Returns the other
  /// side's key alongside the view, or an error. That key is for the caller
  /// to send over the partners' encrypted channel; it is never kept here.
  Future<({ChastityTimerView? view, String? partnerKey, String? error})> create({
    required ChastityTimerConfig config,
    required TimerRole role,
    String? partnerCode,
    String? partnerName,
  }) async {
    final response = await _call('POST', Uri.parse(apiBase), body: {
      'managedBy': role.name,
      'config': config.toJson(),
    });
    if (!response.ok) return (view: null, partnerKey: null, error: response.error ?? 'offline');

    final id = response.body['id'] as String;
    final playerKey = response.body['playerKey'] as String;
    final directorKey = response.body['directorKey'] as String;
    final record = TimerRecord(
      id: id,
      role: role,
      key: role == TimerRole.player ? playerKey : directorKey,
      partnerCode: partnerCode,
      partnerName: partnerName,
      addedAt: DateTime.now(),
    );
    _records.add(record);
    await _save();
    final view = await refresh(id);
    return (
      view: view,
      partnerKey: role == TimerRole.player ? directorKey : playerKey,
      error: view == null ? 'offline' : null,
    );
  }

  /// Adds a timer a partner shared with this device.
  Future<ChastityTimerView?> addShared({
    required String id,
    required TimerRole role,
    required String key,
    String? partnerCode,
    String? partnerName,
  }) async {
    if (recordOf(id) == null) {
      _records.add(TimerRecord(
        id: id,
        role: role,
        key: key,
        partnerCode: partnerCode,
        partnerName: partnerName,
        addedAt: DateTime.now(),
      ));
      await _save();
    }
    return refresh(id);
  }

  /// Forgets a timer on this device. It carries on, on the Worker, for
  /// anyone else with a key.
  Future<void> forget(String id) async {
    _records.removeWhere((r) => r.id == id);
    _views.remove(id);
    await NotificationService.cancelNotification(_notificationId(id));
    await _save();
    notifyListeners();
  }

  /// Asks the Worker for the timer as it stands.
  Future<ChastityTimerView?> refresh(String id) async {
    final record = recordOf(id);
    if (record == null) return null;
    final response = await _call('GET', Uri.parse('$apiBase/$id/view'), key: record.key);
    if (!response.ok) {
      if (response.status == 403 || response.status == 404) {
        // Deleted on the Worker (kept 30 days after the end), or the key no
        // longer works. Nothing more can be done with it here.
        _views.remove(id);
        notifyListeners();
      }
      return null;
    }
    return _accept(response.body);
  }

  Future<void> refreshAll() async {
    for (final r in List.of(_records)) {
      await refresh(r.id);
    }
  }

  /// Adds (positive) or removes (negative) time. Returns an error code on
  /// refusal - a cap, a permission, the timer being over.
  Future<String?> adjust(String id, Duration change) => _act(
        id,
        'adjust',
        {'delta': change.inSeconds, 'eventId': const Uuid().v4()},
      );

  /// Changes the settings the Worker still allows changing. Manager only.
  Future<String?> configure(String id, Map<String, dynamic> changes) =>
      _act(id, 'configure', {'config': changes});

  /// Retires the public link and issues a new one. Manager only.
  Future<String?> replaceLink(String id) => _act(id, 'replace-link', const {}, thenRefresh: true);

  /// The player's emergency release, or the director ending it early.
  Future<String?> release(String id) => _act(id, 'release', const {});

  Future<String?> _act(String id, String op, Map<String, dynamic> body, {bool thenRefresh = false}) async {
    final record = recordOf(id);
    if (record == null) return 'not your timer';
    final response = await _call('POST', Uri.parse('$apiBase/$id/$op'), key: record.key, body: body);
    // A refusal still carries the timer as it stands, so show that.
    if (response.body['status'] is String) _accept(response.body);
    if (thenRefresh) await refresh(id);
    return response.ok ? null : (response.error ?? 'offline');
  }

  ChastityTimerView _accept(Map<String, dynamic> json) {
    final view = ChastityTimerView.fromJson(json);
    _views[view.id] = view;
    _armEndNotification(view);
    notifyListeners();
    return view;
  }

  static int _notificationId(String timerId) => 700000 + (timerId.hashCode & 0xFFFF);

  /// A notification at the end this device was last told about. Discreet on
  /// purpose: it shows on a lock screen.
  void _armEndNotification(ChastityTimerView view) {
    final id = _notificationId(view.id);
    if (view.isOver || view.endAt == null) {
      NotificationService.cancelNotification(id);
      return;
    }
    // In device time: the Worker's end, corrected for this clock's drift.
    final localEnd = view.endAt!.subtract(view.clockOffset);
    NotificationService.scheduleExactNotification(
      id: id,
      title: 'Timer finished',
      body: 'Your timer is done. Open the app for details.',
      scheduledDate: localEnd,
    );
  }

  Future<TimerApiResponse> _call(String method, Uri url, {String? key, Object? body}) async {
    try {
      return await request(method, url, key: key, body: body);
    } catch (e) {
      if (kDebugMode) print('ChastityTimerService: $method $url failed: $e');
      return const TimerApiResponse(0, {'error': 'offline'});
    }
  }

  static Future<TimerApiResponse> _requestOverHttps(String method, Uri url, {String? key, Object? body}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.openUrl(method, url).timeout(const Duration(seconds: 10));
      req.headers.contentType = ContentType.json;
      if (key != null) req.headers.set('X-Timer-Key', key);
      if (body != null) req.write(jsonEncode(body));
      final res = await req.close().timeout(const Duration(seconds: 15));
      final text = await res.transform(utf8.decoder).join();
      Map<String, dynamic> decoded;
      try {
        final parsed = jsonDecode(text);
        decoded = parsed is Map ? Map<String, dynamic>.from(parsed) : {};
      } catch (_) {
        decoded = {};
      }
      return TimerApiResponse(res.statusCode, decoded);
    } finally {
      client.close(force: true);
    }
  }
}
