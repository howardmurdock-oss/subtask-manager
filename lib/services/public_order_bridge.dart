import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/notifications/notification_service.dart';
import '../core/security/proof_crypto.dart';
import '../models/active_order.dart';
import '../models/chastity_timer.dart';
import 'chastity_timer_service.dart';
import 'order_engine.dart';

/// Where a public order's proof goes, as the player's app sees it.
enum PublicProofDestination {
  /// Encrypted to whoever sent the order.
  issuer,

  /// To the timer's director, through the usual review.
  director,

  /// Nowhere: it stays in the player's own log.
  none,
}

/// A public order's link to its timer, kept until its result is reported.
class _Delivery {
  _Delivery({required this.timerId, required this.no, this.issuerKey, required this.proofTo, this.reported = false});

  final String timerId;
  final int no;
  final String? issuerKey;
  final PublicProofTo proofTo;
  bool reported;

  Map<String, dynamic> toJson() =>
      {'timerId': timerId, 'no': no, 'issuerKey': issuerKey, 'proofTo': proofTo.name, 'reported': reported};

  factory _Delivery.fromJson(Map<String, dynamic> j) => _Delivery(
        timerId: j['timerId'] as String,
        no: (j['no'] as num).toInt(),
        issuerKey: j['issuerKey'] as String?,
        proofTo: j['proofTo'] == 'issuer' ? PublicProofTo.issuer : PublicProofTo.director,
        reported: j['reported'] == true,
      );
}

/// Carries orders the public sent from a timer's page into the player's own
/// list - so they get the usual timers, proof and tokens - and carries the
/// result of each back to the Worker.
///
/// Done or failed, the tokens are the engine's as for any order. Proof goes
/// to the director through the usual review, whose approval completes it;
/// or, encrypted, to whoever sent the order; or, with neither, stays here.
class PublicOrderBridge {
  PublicOrderBridge({required this.engine, required this.timers});

  final OrderEngine engine;
  final ChastityTimerService timers;

  static const String prefsKey = 'chastity_timer_public_orders_v1';

  /// Orders already announced, shared with [TimerNotice] in the background.
  static const String announcedKey = 'chastity_timer_order_notices_v1';

  final Map<String, _Delivery> _deliveries = {};
  final Set<String> _inFlight = {};
  bool _started = false;

  static String activeIdFor(String timerId, int no) => 'public-$timerId-$no';
  static bool isPublic(ActiveOrder order) => order.id.startsWith('public-');

  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw != null) {
        (jsonDecode(raw) as Map).forEach((k, v) {
          _deliveries[k as String] = _Delivery.fromJson(Map<String, dynamic>.from(v as Map));
        });
      }
    } catch (_) {}
    timers.addListener(_onTimers);
    engine.addListener(_onEngine);
    _onTimers();
    _onEngine();
  }

  void dispose() {
    timers.removeListener(_onTimers);
    engine.removeListener(_onEngine);
  }

  /// Where proof for [order] goes, and the timer's director when that is
  /// where. Null for an order that is not a public one.
  ({PublicProofDestination to, String? directorCode, String? directorName})? destinationOf(ActiveOrder order) {
    final d = _deliveries[order.id];
    if (d == null) return null;
    if (d.proofTo == PublicProofTo.issuer) {
      return (to: d.issuerKey == null ? PublicProofDestination.none : PublicProofDestination.issuer, directorCode: null, directorName: null);
    }
    final record = timers.recordOf(d.timerId);
    if (record?.partnerCode == null) return (to: PublicProofDestination.none, directorCode: null, directorName: null);
    return (to: PublicProofDestination.director, directorCode: record!.partnerCode, directorName: record.partnerName);
  }

  /// The public order on [timerId] now in this device's list, if any.
  ActiveOrder? currentFor(String timerId) {
    for (final e in _deliveries.entries) {
      if (e.value.timerId != timerId || e.value.reported) continue;
      final order = engine.activeOrders.where((o) => o.id == e.key).firstOrNull;
      if (order != null) return order;
    }
    return null;
  }

  /// Skips left today on [order]'s timer.
  int skipsLeftFor(ActiveOrder order) {
    final d = _deliveries[order.id];
    return d == null ? 0 : (timers.viewOf(d.timerId)?.orders?.skipsLeft ?? 0);
  }

  /// Done, with proof for its sender (encrypted) or for nobody: reported,
  /// then completed here, which pays its tokens. Proof for the director
  /// goes through the usual review instead. Returns an error, or null.
  Future<String?> submit(ActiveOrder order, {String? note, String? imageBase64}) async {
    final d = _deliveries[order.id];
    if (d == null) return 'not-active';
    _inFlight.add(order.id);
    try {
      final proof = d.proofTo == PublicProofTo.issuer && d.issuerKey != null
          ? _encryptProof(d.issuerKey!, imageBase64: imageBase64, note: note)
          : null;
      final error = await timers.reportPublicOrder(d.timerId, d.no, completed: true, proof: proof);
      if (error != null && error != 'not-active') return error;
      d.reported = true;
      await _save();
      engine.completeOrder(order.id, proofNote: note);
      return error;
    } finally {
      _inFlight.remove(order.id);
    }
  }

  /// Skips the order: no penalty, and a pause before the next. Returns an
  /// error, or null.
  Future<String?> skip(String activeId) async {
    final d = _deliveries[activeId];
    if (d == null) return 'not-active';
    final error = await timers.skipPublicOrder(d.timerId, d.no);
    if (error != null && error != 'not-active') return error;
    d.reported = true;
    await _save();
    engine.removeActiveOrder(activeId);
    return null;
  }

  // ---- Delivery -------------------------------------------------------------

  void _onTimers() {
    for (final r in timers.records) {
      if (r.role != TimerRole.player) continue;
      final orders = timers.viewOf(r.id)?.orders;
      if (orders == null) continue;
      final active = orders.active;
      if (active != null) _deliver(r.id, active, orders.proofTo);
      _settleFromFeed(r.id, orders);
    }
  }

  Future<void> _deliver(String timerId, PublicOrderActive active, PublicProofTo proofTo) async {
    final id = activeIdFor(timerId, active.no);
    if (_deliveries.containsKey(id)) return;
    _deliveries[id] = _Delivery(timerId: timerId, no: active.no, issuerKey: active.issuerKey, proofTo: proofTo);
    await _save();
    engine.assignOrder(
      active.def.toOrder(id: 'public-${active.def.id}'),
      id: id,
      assignedByPartnerId: 'public',
      assignedByPartnerName: 'the public',
      assignedAt: active.deliveredAt,
    );
    await announce(timerId, active.no, active.def);
  }

  /// One the Worker settled without this device - it ran out of time there,
  /// or the timer ended - is settled here too.
  void _settleFromFeed(String timerId, PublicOrdersStatus orders) {
    for (final f in orders.feed) {
      final id = activeIdFor(timerId, f.no);
      final d = _deliveries[id];
      if (d == null || d.reported) continue;
      final order = engine.activeOrders.where((o) => o.id == id).firstOrNull;
      if (f.status == 'expired') {
        d.reported = true;
        if (order != null && order.status != OrderStatus.completed && order.status != OrderStatus.failed) {
          engine.failOrder(id, reason: 'Ran out of time');
        }
      } else if (f.status == 'cancelled' || f.status == 'skipped') {
        d.reported = true;
        if (order != null) engine.removeActiveOrder(id);
      }
    }
    _save();
  }

  /// Tells the player a public order has arrived - once, whichever of the
  /// app or a background push gets there first.
  static Future<void> announce(String timerId, int no, PublicOrderDef def) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final key = '$timerId-$no';
      final done = List<String>.from(prefs.getStringList(announcedKey) ?? const <String>[]);
      if (done.contains(key)) return;
      done.add(key);
      if (done.length > 200) done.removeRange(0, done.length - 200);
      await prefs.setStringList(announcedKey, done);
      await NotificationService.showOrderDispatchedNotification(
        title: def.title,
        description: def.description,
        assignerName: 'the public',
        rewardTokens: def.rewardTokens,
      );
    } catch (e) {
      if (kDebugMode) print('PublicOrderBridge.announce error: $e');
    }
  }

  // ---- Results ---------------------------------------------------------------

  void _onEngine() {
    for (final e in _deliveries.entries.toList()) {
      if (e.value.reported || _inFlight.contains(e.key)) continue;
      final order = engine.activeOrders.where((o) => o.id == e.key).firstOrNull;
      if (order == null) continue;
      switch (order.status) {
        case OrderStatus.completed:
          _report(e.key, e.value, completed: true);
        case OrderStatus.failed:
          _report(e.key, e.value, completed: false);
        case OrderStatus.underReview:
          // Proof for the director waits for their review; any other kind
          // is sent on, and the order completed here.
          final to = destinationOf(order)?.to;
          if (to != PublicProofDestination.director) _report(e.key, e.value, completed: true, withProof: order);
        default:
          break;
      }
    }
  }

  Future<void> _report(String id, _Delivery d, {required bool completed, ActiveOrder? withProof}) async {
    _inFlight.add(id);
    try {
      String? proof;
      if (withProof != null && d.proofTo == PublicProofTo.issuer && d.issuerKey != null) {
        proof = _encryptProof(d.issuerKey!, imageBase64: withProof.proofImageBase64, note: withProof.submissionProof);
      }
      final error = await timers.reportPublicOrder(d.timerId, d.no, completed: completed, proof: proof);
      // Too late (it ran out of time on the Worker) counts as settled; any
      // other failure is tried again on the next change.
      if (error != null && error != 'not-active') return;
      d.reported = true;
      await _save();
      if (withProof != null) engine.completeOrder(id);
    } finally {
      _inFlight.remove(id);
    }
  }

  /// The photo if there is one, otherwise the note, encrypted for the sender.
  static String? _encryptProof(String issuerKey, {String? imageBase64, String? note}) {
    try {
      final image = imageBase64;
      if (image != null && image.isNotEmpty) {
        final bytes = base64.decode(image.contains(',') ? image.split(',').last : image);
        return ProofCrypto.encrypt(issuerKey, Uint8List.fromList(bytes), _mimeOf(bytes));
      }
      if (note != null && note.trim().isNotEmpty) {
        return ProofCrypto.encrypt(issuerKey, Uint8List.fromList(utf8.encode(note.trim())), 'text/plain');
      }
    } catch (e) {
      if (kDebugMode) print('PublicOrderBridge: proof not encrypted: $e');
    }
    return null;
  }

  static String _mimeOf(List<int> b) {
    if (b.length > 3 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4e) return 'image/png';
    if (b.length > 12 && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) return 'image/webp';
    return 'image/jpeg';
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Settled ones are kept a while for de-duplication, then dropped.
      if (_deliveries.length > 300) {
        final settled = _deliveries.entries.where((e) => e.value.reported).map((e) => e.key).toList();
        for (final k in settled.take(_deliveries.length - 300)) {
          _deliveries.remove(k);
        }
      }
      await prefs.setString(prefsKey, jsonEncode(_deliveries.map((k, v) => MapEntry(k, v.toJson()))));
    } catch (_) {}
  }
}

/// The bridge, for screens that need it. Set at startup.
PublicOrderBridge? publicOrderBridge;
