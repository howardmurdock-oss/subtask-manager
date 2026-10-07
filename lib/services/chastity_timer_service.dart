import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/notifications/notification_service.dart';
import '../models/chastity_timer.dart';
import 'push_service.dart';
import 'timer_notice.dart';

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
    case 'partner-connected':
      return 'They already have this timer.';
    case 'at-maximum':
      return 'This timer is already at its maximum length. No more time can be added.';
    case 'too-many-changes':
      return 'This timer has had as many changes as it can take.';
    case 'bad-amount':
      return "That amount can't be used.";
    case 'not your timer':
      return "This device doesn't have access to that timer any more.";
    case 'no such timer':
      return 'That timer no longer exists.';
    case 'slow-down':
      return 'Too many tries just now. Wait a minute, then try again.';
    case 'link-changes':
      return "The link has been changed too often today. You can still switch it off; a new one can be made tomorrow.";
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

  /// Finished timers whose end this device has shown its person.
  static const String seenFinishedKey = 'chastity_timer_seen_finished_v1';

  /// Timers sent while another was running, waiting for a yes or no.
  static const String invitesKey = 'chastity_timer_invites_v1';

  /// Timers of this device's that the player declined.
  static const String declinedKey = 'chastity_timer_declined_v1';

  final List<TimerInvite> _invites = [];
  final Set<String> _declined = {};
  final _inviteArrived = StreamController<TimerInvite>.broadcast();

  /// Requests waiting for an answer, oldest first.
  List<TimerInvite> get invites => List.unmodifiable(_invites);

  /// Fires as a request arrives.
  Stream<TimerInvite> get inviteArrived => _inviteArrived.stream;

  /// Whether the player declined this timer, which this device sent.
  bool wasDeclined(String id) => _declined.contains(id);

  /// Timers this device is the player on that are certainly still running.
  /// One not fetched yet is not counted: it may long since have ended.
  List<TimerRecord> runningAsPlayer() => _records
      .where((r) => r.role == TimerRole.player)
      .where((r) => _views[r.id] != null && !_views[r.id]!.isOver)
      .toList();

  /// Holds a timer sent while another is running, for the player to answer.
  /// The same timer sent again (a key sent again) replaces the request.
  Future<void> addInvite(TimerInvite invite) async {
    final fresh = !_invites.any((i) => i.id == invite.id);
    _invites
      ..removeWhere((i) => i.id == invite.id)
      ..add(invite);
    await _saveInvites();
    notifyListeners();
    if (fresh) _inviteArrived.add(invite);
  }

  /// A look at a requested timer before answering: its length, its reward,
  /// whether it uses a combination.
  Future<ChastityTimerView?> peekInvite(TimerInvite invite) async {
    final response = await _call('GET', Uri.parse('$apiBase/${invite.id}/view'), key: invite.key);
    return response.ok ? ChastityTimerView.fromJson(response.body) : null;
  }

  /// Takes the timer on. Null if it could not be reached; the request stays.
  Future<ChastityTimerView?> acceptInvite(String id) async {
    final invite = _invites.where((i) => i.id == id).firstOrNull;
    if (invite == null) return null;
    final view = await addShared(
      id: invite.id,
      role: TimerRole.player,
      key: invite.key,
      partnerCode: invite.partnerCode,
      partnerName: invite.partnerName,
    );
    if (view == null) return null;
    _invites.removeWhere((i) => i.id == id);
    await _saveInvites();
    notifyListeners();
    return view;
  }

  /// Turns the request down. The caller tells the director.
  Future<TimerInvite?> declineInvite(String id) async {
    final invite = _invites.where((i) => i.id == id).firstOrNull;
    if (invite == null) return null;
    _invites.removeWhere((i) => i.id == id);
    await _saveInvites();
    notifyListeners();
    return invite;
  }

  /// The player turned down a timer this device sent them: it is ended, as
  /// nobody is on the other end of it.
  Future<void> markDeclined(String id) async {
    if (!_declined.add(id)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(declinedKey, _declined.toList());
    } catch (_) {}
    await release(id);
  }

  Future<void> _saveInvites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(invitesKey, jsonEncode(_invites.map((i) => i.toJson()).toList()));
    } catch (_) {}
  }

  /// The player's public page, if they have made one.
  static const String profileKey = 'chastity_timer_profile_v1';

  /// Timers the page has been told of.
  static const String profileTimersKey = 'chastity_timer_profile_timers_v1';

  /// Where a player's page is served.
  static const String profileLinkBase = 'https://subtaskmanager.com/p/';

  TimerProfile? _profile;
  final Set<String> _profileTimers = {};

  TimerProfile? get profile => _profile;
  String? get profileLink => _profile == null ? null : '$profileLinkBase${_profile!.publicId}';

  /// Makes the player's page, and tells it of every timer they are on.
  Future<String?> createProfile({String? name}) async {
    final response = await _call('POST', Uri.parse('${PushService.workerBaseUrl}/profile'), body: {'name': name});
    if (!response.ok) return response.error ?? 'offline';
    _profile = TimerProfile(
      profileId: response.body['profileId'] as String,
      key: response.body['key'] as String,
      publicId: response.body['publicId'] as String,
      name: response.body['name'] as String?,
    );
    _profileTimers.clear();
    await _saveProfile();
    notifyListeners();
    await _tellProfileAll();
    return null;
  }

  /// Changes the name shown on it, or whether past timers are listed.
  Future<String?> updateProfile({String? name, bool clearName = false, bool? showHistory}) async {
    final p = _profile;
    if (p == null) return 'no-profile';
    final response = await _profileCall('settings', {
      if (name != null || clearName) 'name': clearName ? null : name,
      if (showHistory != null) 'showHistory': showHistory,
    });
    if (!response.ok) return response.error ?? 'offline';
    _profile = p.copyWith(
      name: response.body['name'] as String?,
      clearName: response.body['name'] == null,
      showHistory: response.body['showHistory'] == true,
    );
    await _saveProfile();
    notifyListeners();
    return null;
  }

  /// A new link for the page. The old one stops working.
  Future<String?> newProfileLink() async {
    final p = _profile;
    if (p == null) return 'no-profile';
    final response = await _profileCall('new-link', const {});
    if (!response.ok) return response.error ?? 'offline';
    _profile = p.copyWith(publicId: response.body['publicId'] as String);
    await _saveProfile();
    notifyListeners();
    return null;
  }

  /// The page as a code, for moving it to another device. Whoever has it can
  /// take the page over.
  String? exportProfile() => _profile == null ? null : 'stp1.${_profile!.profileId}.${_profile!.key}';

  /// Takes over a page exported from another device. That device can no
  /// longer change it. Returns an error, or null.
  Future<String?> importProfile(String code) async {
    final parts = code.trim().split('.');
    if (parts.length != 3 || parts[0] != 'stp1' || parts[1].isEmpty || parts[2].isEmpty) return 'bad-code';
    final response = await _call('POST', Uri.parse('${PushService.workerBaseUrl}/profile/${parts[1]}/rekey'),
        key: parts[2], body: const {});
    if (response.status == 403) return 'bad-code';
    if (!response.ok) return response.error ?? 'offline';
    _profile = TimerProfile(
      profileId: parts[1],
      key: response.body['key'] as String,
      publicId: response.body['publicId'] as String,
      name: response.body['name'] as String?,
      showHistory: response.body['showHistory'] == true,
    );
    _profileTimers
      ..clear()
      ..addAll(((response.body['timers'] as List?) ?? const []).whereType<String>());
    await _saveProfile();
    notifyListeners();
    await _tellProfileAll();
    return null;
  }

  Future<TimerApiResponse> _profileCall(String op, Map<String, dynamic> body) => _call(
      'POST', Uri.parse('${PushService.workerBaseUrl}/profile/${_profile!.profileId}/$op'),
      key: _profile!.key, body: body);

  /// Tells the page of a timer this device is the player on. Which of them
  /// show is the Worker's to decide, each time: link on, and on a director's
  /// timer only if they gave the player the link.
  Future<void> _tellProfile(TimerRecord record) async {
    if (_profile == null || record.role != TimerRole.player || _profileTimers.contains(record.id)) return;
    final response = await _profileCall('add', {'timerId': record.id, 'timerKey': record.key});
    if (!response.ok) return;
    _profileTimers.add(record.id);
    await _saveProfile();
  }

  Future<void> _tellProfileAll() async {
    for (final r in List.of(_records)) {
      await _tellProfile(r);
    }
  }

  Future<void> _saveProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_profile == null) {
        await prefs.remove(profileKey);
      } else {
        await prefs.setString(profileKey, jsonEncode(_profile!.toJson()));
      }
      await prefs.setStringList(profileTimersKey, _profileTimers.toList());
    } catch (_) {}
  }

  /// The last view of each timer, kept so a relaunch knows straight away
  /// which are over - and counts the running ones down from where they were
  /// - instead of showing every timer as running until the Worker answers.
  static const String viewsKey = 'chastity_timer_views_v1';

  /// Timers whose key the Worker no longer accepts: not counted as running.
  static const String lostKey = 'chastity_timer_lost_v1';

  final Map<String, Map<String, dynamic>> _savedViews = {};
  final Set<String> _lost = {};

  /// Whether this device's key to [id] no longer works.
  bool isLost(String id) => _lost.contains(id);

  Future<void> _saveViews() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(viewsKey, jsonEncode(_savedViews));
      await prefs.setStringList(lostKey, _lost.toList());
    } catch (_) {}
  }

  /// Timers whose reward this device has credited.
  static const String rewardedKey = 'chastity_timer_rewarded_v1';

  /// A timer's view, fetched with [key] - for code outside this service that
  /// runs without it, such as a push handled in the background.
  static Future<TimerApiResponse> fetchView(String id, String key) =>
      request('GET', Uri.parse('$apiBase/$id/view'), key: key);

  /// Credits a completed timer's reward to the player: set by the sync
  /// service, which holds the token balance. Called once per timer.
  void Function(ChastityTimerView view, int tokens)? onReward;
  final Set<String> _rewarded = {};

  /// Where the public link page is served (a route on the website's domain).
  static const String publicLinkBase = 'https://subtaskmanager.com/t/';

  static String get apiBase => '${PushService.workerBaseUrl}/timer';

  /// Where this device listens for messages (its relay topic). Set by the
  /// sync service; the player's timers are told it, so public additions can
  /// be announced.
  static String? Function()? ownTopic;

  /// Per timer, the topic the Worker was last told.
  static const String notifyTopicsKey = 'chastity_timer_notify_topics_v1';

  /// Swapped out in tests; the real one talks to the Worker over HTTPS.
  @visibleForTesting
  static Future<TimerApiResponse> Function(String method, Uri url, {String? key, Object? body}) request =
      _requestOverHttps;

  final List<TimerRecord> _records = [];
  final Map<String, ChastityTimerView> _views = {};
  bool _loaded = false;

  /// A timer that is over stays in front of its person until they have seen
  /// how it ended - above all the combination. "No timer running" was true
  /// the moment it ended, and hid the one thing they were waiting for.
  final Set<String> _seenFinished = {};

  /// Timers already announced through [justFinished] this session.
  final Set<String> _announced = {};
  final _finished = StreamController<ChastityTimerView>.broadcast();

  /// Fires once per timer, the first time this device sees it over and not
  /// yet seen - as it ends while the app is open, or on the next launch.
  Stream<ChastityTimerView> get justFinished => _finished.stream;

  Timer? _watchdog;
  final Map<String, DateTime> _lastFetched = {};

  List<TimerRecord> get records => List.unmodifiable(_records);
  ChastityTimerView? viewOf(String id) => _views[id];
  bool get isLoaded => _loaded;

  /// Timers not yet over, most recent first, for this device's [role].
  List<TimerRecord> active({TimerRole? role}) => _records
      .where((r) => role == null || r.role == role)
      .where((r) => !(_views[r.id]?.isOver ?? false) && !_lost.contains(r.id))
      .toList()
    ..sort((a, b) => b.addedAt.compareTo(a.addedAt));

  static String publicLinkFor(String publicId) => '$publicLinkBase$publicId';

  /// Whether [id] is over and its person has not yet seen how it ended.
  bool needsAttention(String id) =>
      (_views[id]?.isOver ?? false) && !_seenFinished.contains(id);

  /// Finished timers not yet seen, most recent first, for [role].
  List<TimerRecord> finishedUnseen({TimerRole? role}) => _records
      .where((r) => role == null || r.role == role)
      .where((r) => needsAttention(r.id))
      .toList()
    ..sort((a, b) => b.addedAt.compareTo(a.addedAt));

  /// Marks a finished timer as seen, so it stops being put in front of them.
  Future<void> acknowledge(String id) async {
    if (!(_views[id]?.isOver ?? false) || !_seenFinished.add(id)) return;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(seenFinishedKey, _seenFinished.toList());
    } catch (_) {}
  }

  /// Notices timers ending while the app is open.
  ///
  /// The end is only known for certain by the Worker - and only the Worker
  /// hands over the combination. So a timer is fetched again as its end
  /// passes on this clock, and a hidden one, whose end this device does not
  /// know, once a minute.
  void startWatching({Duration every = const Duration(seconds: 10)}) {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(every, (_) => _watch());
  }

  Future<void> _watch() async {
    final now = DateTime.now();
    for (final r in List.of(_records)) {
      final view = _views[r.id];
      if (view == null || view.status != TimerStatus.running) continue;
      final pastEnd = view.endAt != null && !view.serverNow.isBefore(view.endAt!);
      final last = _lastFetched[r.id];
      final stale = view.endAt == null && (last == null || now.difference(last) >= const Duration(minutes: 1));
      // Public orders arrive by push; this catches any that did not.
      final ordersDue = view.config.publicOrders.enabled &&
          (last == null || now.difference(last) >= const Duration(minutes: 2));
      if (ordersDue) {
        await refresh(r.id);
        continue;
      }
      if (pastEnd || stale) await refresh(r.id);
    }
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    _finished.close();
    _inviteArrived.close();
    super.dispose();
  }

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
      _seenFinished
        ..clear()
        ..addAll(prefs.getStringList(seenFinishedKey) ?? const []);
      _rewarded
        ..clear()
        ..addAll(prefs.getStringList(rewardedKey) ?? const []);
      _declined
        ..clear()
        ..addAll(prefs.getStringList(declinedKey) ?? const []);
      _lost
        ..clear()
        ..addAll(prefs.getStringList(lostKey) ?? const []);
      _savedViews.clear();
      final rawViews = prefs.getString(viewsKey);
      if (rawViews != null) {
        (jsonDecode(rawViews) as Map).forEach((id, saved) {
          if (saved is! Map || recordOf(id as String) == null) return;
          final json = Map<String, dynamic>.from(saved['json'] as Map);
          final at = DateTime.fromMillisecondsSinceEpoch((saved['at'] as num).toInt());
          _savedViews[id] = Map<String, dynamic>.from(saved);
          // As it was when last fetched, on the Worker's clock: a timer that
          // has since run out shows as over at once.
          _views[id] = ChastityTimerView.fromJson(json, receivedAt: at);
        });
      }
      final rawProfile = prefs.getString(profileKey);
      _profile = rawProfile == null ? null : TimerProfile.fromJson(Map<String, dynamic>.from(jsonDecode(rawProfile) as Map));
      _profileTimers
        ..clear()
        ..addAll(prefs.getStringList(profileTimersKey) ?? const []);
      final rawInvites = prefs.getString(invitesKey);
      _invites
        ..clear()
        ..addAll(rawInvites == null
            ? const []
            : (jsonDecode(rawInvites) as List)
                .whereType<Map>()
                .map((m) => TimerInvite.fromJson(Map<String, dynamic>.from(m))));
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
    final existing = recordOf(id);
    if (existing == null || existing.key != key) {
      // A key sent again replaces an earlier one, which no longer works.
      _records.removeWhere((r) => r.id == id);
      _records.add(TimerRecord(
        id: id,
        role: role,
        key: key,
        partnerCode: partnerCode ?? existing?.partnerCode,
        partnerName: partnerName ?? existing?.partnerName,
        addedAt: existing?.addedAt ?? DateTime.now(),
      ));
      await _save();
    }
    return refresh(id);
  }

  /// Forgets a timer on this device. It carries on, on the Worker, for
  /// anyone else with a key.
  Future<void> forget(String id) async {
    // Gone from the device: gone from the player's page too.
    if (_profile != null && _profileTimers.remove(id)) {
      await _profileCall('remove', {'timerId': id});
      await _saveProfile();
    }
    _records.removeWhere((r) => r.id == id);
    _views.remove(id);
    _savedViews.remove(id);
    _lost.remove(id);
    await _saveViews();
    await NotificationService.cancelNotification(_notificationId(id));
    await _save();
    notifyListeners();
  }

  /// Asks the Worker for the timer as it stands.
  Future<ChastityTimerView?> refresh(String id) async {
    final record = recordOf(id);
    if (record == null) return null;
    _lastFetched[id] = DateTime.now();
    final response = await _call('GET', Uri.parse('$apiBase/$id/view'), key: record.key);
    if (!response.ok) {
      if (response.status == 404) {
        // Deleted on the Worker, 30 days after it ended: nothing is left to
        // show. It used to stay here, counted as running for ever.
        await forget(id);
      } else if (response.status == 403) {
        // The key no longer works (replaced, say): kept, but not running.
        _lost.add(id);
        _views.remove(id);
        _savedViews.remove(id);
        await _saveViews();
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

  /// A fresh key for the partner, whose first one never arrived - to send
  /// again. Manager only, and only while the partner has never connected.
  Future<({String? key, String? error})> reissuePartnerKey(String id) async {
    final record = recordOf(id);
    if (record == null) return (key: null, error: 'not your timer');
    final response = await _call('POST', Uri.parse('$apiBase/$id/reissue-key'), key: record.key, body: const {});
    if (!response.ok) return (key: null, error: response.error ?? 'offline');
    return (key: response.body['key'] as String?, error: null);
  }

  /// The player's emergency release, or the director ending it early.
  Future<String?> release(String id) => _act(id, 'release', const {});

  /// The player's result for public order [no]: done (with any proof,
  /// already encrypted for its sender) or failed.
  Future<String?> reportPublicOrder(String id, int no, {required bool completed, String? proof}) =>
      _act(id, 'order-result', {'no': no, 'result': completed ? 'completed' : 'failed', if (proof != null) 'proof': proof});

  /// Done, with proof to be checked by whoever receives it - approved or
  /// rejected by them, or approved for them if they take too long.
  Future<String?> submitPublicOrder(String id, int no, {String? proof}) =>
      _act(id, 'order-result', {'no': no, 'result': 'submitted', if (proof != null) 'proof': proof});

  /// Skips public order [no]: no penalty, and a pause before the next.
  Future<String?> skipPublicOrder(String id, int no) => _act(id, 'order-skip', {'no': no});

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
    _savedViews[view.id] = {'json': json, 'at': DateTime.now().millisecondsSinceEpoch};
    _lost.remove(view.id);
    _saveViews();
    _tellTopic(view);
    _creditReward(view);
    final record = recordOf(view.id);
    if (record != null) _tellProfile(record);
    _armEndNotification(view);
    notifyListeners();
    if (view.isOver && !_seenFinished.contains(view.id) && _announced.add(view.id)) {
      _finished.add(view);
    }
    return view;
  }

  /// A completed timer's reward, credited on the player's device - where
  /// the balance is - once. Recorded before it is credited: a crash between
  /// the two loses a reward rather than paying it twice.
  Future<void> _creditReward(ChastityTimerView view) async {
    final record = recordOf(view.id);
    if (!_loaded || record == null || record.role != TimerRole.player) return;
    if (!view.earnedReward || !_rewarded.add(view.id)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(rewardedKey, _rewarded.toList());
    } catch (_) {}
    onReward?.call(view, view.config.rewardTokens!);
  }

  /// A player's timer is told where this device listens, once, and again
  /// whenever that changes.
  Future<void> _tellTopic(ChastityTimerView view) async {
    final topic = ownTopic?.call();
    final record = recordOf(view.id);
    if (topic == null || record == null || record.role != TimerRole.player || view.isOver) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final told = Map<String, dynamic>.from(jsonDecode(prefs.getString(notifyTopicsKey) ?? '{}') as Map);
      if (told[view.id] == topic) return;
      await TimerNotice.startCounting(view.id, view.serverNow);
      final response = await _call('POST', Uri.parse('$apiBase/${view.id}/notify-topic'),
          key: record.key, body: {'topic': topic});
      if (!response.ok) return;
      told[view.id] = topic;
      await prefs.setString(notifyTopicsKey, jsonEncode(told));
    } catch (e) {
      if (kDebugMode) print('ChastityTimerService: topic error: $e');
    }
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
