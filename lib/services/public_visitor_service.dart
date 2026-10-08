import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/security/proof_crypto.dart';
import 'push_service.dart';

/// A reply from the Worker: its status and JSON body.
class VisitorResponse {
  const VisitorResponse(this.status, this.body);

  final int status;
  final Map<String, dynamic> body;

  bool get ok => status >= 200 && status < 300;
  String? get error => body['error'] as String?;
}

/// A public timer or player page, as anyone may see it.
class PublicPage {
  const PublicPage({required this.kind, required this.id, required this.state});

  /// 't' for a timer's page, 'p' for a player's.
  final String kind;
  final String id;
  final Map<String, dynamic> state;

  /// The timer shown: the page's own, or the player's current one.
  Map<String, dynamic>? get timer =>
      kind == 't' ? state : (state['featured'] is Map ? Map<String, dynamic>.from(state['featured'] as Map) : null);

  /// The timer's own link id - what votes and orders go to.
  String? get timerId => kind == 't' ? id : timer?['publicId'] as String?;

  String? get name => kind == 'p' ? state['name'] as String? : null;

  Map<String, dynamic>? get orders {
    final o = timer?['orders'];
    return o is Map && o['enabled'] == true ? Map<String, dynamic>.from(o) : null;
  }
}

/// One order this app sent from a public page.
class SentOrder {
  const SentOrder({required this.timerId, required this.no, required this.receipt, required this.title, required this.at});

  final String timerId;
  final int no;
  final String receipt;
  final String title;
  final DateTime at;

  Map<String, dynamic> toJson() =>
      {'timerId': timerId, 'no': no, 'receipt': receipt, 'title': title, 'at': at.millisecondsSinceEpoch};

  factory SentOrder.fromJson(Map<String, dynamic> j) => SentOrder(
        timerId: j['timerId'] as String,
        no: (j['no'] as num).toInt(),
        receipt: j['receipt'] as String,
        title: j['title'] as String? ?? '',
        at: DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt()),
      );
}

/// A public page this app keeps an eye on.
class WatchedPage {
  const WatchedPage({required this.kind, required this.id, this.label});

  final String kind;
  final String id;
  final String? label;

  Map<String, dynamic> toJson() => {'kind': kind, 'id': id, 'label': label};

  factory WatchedPage.fromJson(Map<String, dynamic> j) =>
      WatchedPage(kind: j['kind'] as String, id: j['id'] as String, label: j['label'] as String?);
}

/// This app as a visitor to other people's public timers: voting and sending
/// orders from the app, getting their proof here, and watching timers.
///
/// Votes and orders need a person behind them. A browser shows that with
/// Cloudflare's check each time; the app does it once - in the browser,
/// handing back with a link - which ties this install's friend code to a
/// secret only it holds. After that it proves itself with the secret.
class PublicVisitorService extends ChangeNotifier {
  static const String prefsKey = 'public_visitor_v1';

  /// Where this device listens for messages (its relay topic). Set by the
  /// sync service; sent with orders and watches so this app is told how
  /// they go.
  static String? Function()? ownTopic;
  static const String siteBase = 'https://subtaskmanager.com';

  /// Swapped out in tests.
  @visibleForTesting
  static Future<VisitorResponse> Function(String method, Uri url, {Map<String, String>? headers, Object? body})
      request = _overHttps;

  /// A timer's public page as anyone sees it - for code that runs without
  /// this service, such as a notice handled in the background.
  static Future<VisitorResponse> fetchTimerState(String publicId) =>
      request('GET', Uri.parse('$siteBase/t/$publicId/state'));

  String? _deviceId;
  String? _secret;
  bool _verified = false;
  String? _privateHex;
  String? _publicKey;
  final List<SentOrder> _sent = [];
  final List<WatchedPage> _watching = [];
  bool _loaded = false;

  bool get isVerified => _verified;
  List<SentOrder> get sent => List.unmodifiable(_sent);
  List<WatchedPage> get watching => List.unmodifiable(_watching);
  bool isWatching(String kind, String id) => _watching.any((w) => w.kind == kind && w.id == id);

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        _deviceId = j['deviceId'] as String?;
        _secret = j['secret'] as String?;
        _verified = j['verified'] == true;
        _privateHex = j['privateHex'] as String?;
        _publicKey = j['publicKey'] as String?;
        _sent.addAll(((j['sent'] as List?) ?? const []).whereType<Map>().map((m) => SentOrder.fromJson(Map<String, dynamic>.from(m))));
        _watching.addAll(((j['watching'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => WatchedPage.fromJson(Map<String, dynamic>.from(m))));
      }
    } catch (e) {
      if (kDebugMode) print('PublicVisitorService.load: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Orders older than a few days have nothing left to show.
      _sent.removeWhere((o) => DateTime.now().difference(o.at) > const Duration(days: 3));
      await prefs.setString(
        prefsKey,
        jsonEncode({
          'deviceId': _deviceId,
          'secret': _secret,
          'verified': _verified,
          'privateHex': _privateHex,
          'publicKey': _publicKey,
          'sent': _sent.map((o) => o.toJson()).toList(),
          'watching': _watching.map((w) => w.toJson()).toList(),
        }),
      );
    } catch (_) {}
  }

  Map<String, String> get _deviceHeaders =>
      _deviceId == null || _secret == null ? const {} : {'X-Device-Id': _deviceId!, 'X-Device-Secret': _secret!};

  // ---- Verification -------------------------------------------------------------

  /// Starts the one-time check: registers this install, then opens the check
  /// page in the browser, which hands back to the app when it is passed.
  Future<String?> startVerification() async {
    _secret ??= _random(32);
    final topic = ownTopic?.call() ?? _random(16);
    final response = await _call('POST', Uri.parse('${PushService.workerBaseUrl}/device/start'), body: {
      'codeHash': sha256.convert(utf8.encode(topic)).toString(),
      'secretHash': sha256.convert(utf8.encode(_secret!)).toString(),
    });
    if (!response.ok) return response.error ?? 'offline';
    _deviceId = response.body['deviceId'] as String;
    _verified = false;
    await _save();
    await launchUrl(Uri.parse('$siteBase/app/verify#$_deviceId'), mode: LaunchMode.externalApplication);
    return null;
  }

  /// Asks whether the check has passed - when the page hands back, or the
  /// person returns to the app.
  Future<bool> checkVerified() async {
    if (_deviceId == null) return false;
    final response = await _call('GET', Uri.parse('${PushService.workerBaseUrl}/device/status'), headers: _deviceHeaders);
    _verified = response.ok && response.body['verified'] == true;
    await _save();
    notifyListeners();
    return _verified;
  }

  // ---- Pages ------------------------------------------------------------------------

  Future<PublicPage?> fetch(String kind, String id) async {
    final response = await _call('GET', Uri.parse('$siteBase/$kind/$id/state'));
    return response.ok ? PublicPage(kind: kind, id: id, state: response.body) : null;
  }

  /// Adds or removes time. An error code, or null.
  Future<String?> vote(String timerId, int direction) async {
    final response = await _call('POST', Uri.parse('$siteBase/t/$timerId/vote'),
        headers: _deviceHeaders, body: {'direction': direction});
    return _outcome(response);
  }

  /// Sends one of the page's orders. Proof for this app comes encrypted to
  /// its own key, and its progress to its own address.
  Future<String?> sendOrder(String timerId, Map<String, dynamic> def, {required bool proofToSender}) async {
    final receipt = _random(32);
    if (proofToSender && _publicKey == null) {
      final pair = ProofCrypto.newKeyPair();
      _privateHex = pair.privateHex;
      _publicKey = pair.publicKey;
    }
    final response = await _call('POST', Uri.parse('$siteBase/t/$timerId/order'), headers: _deviceHeaders, body: {
      'orderId': def['id'],
      'receiptHash': sha256.convert(utf8.encode(receipt)).toString(),
      if (proofToSender) 'issuerKey': _publicKey,
      if (ownTopic?.call() != null) 'issuerTopic': ownTopic!.call(),
    });
    final error = _outcome(response);
    if (error == null) {
      _sent.add(SentOrder(
        timerId: timerId,
        no: (response.body['no'] as num).toInt(),
        receipt: receipt,
        title: def['title'] as String? ?? '',
        at: DateTime.now(),
      ));
      await _save();
      notifyListeners();
    }
    return error;
  }

  SentOrder? sentOrder(String timerId, int no) =>
      _sent.where((o) => o.timerId == timerId && o.no == no).firstOrNull;

  /// The proof for an order this app sent, opened with its own key.
  Future<({Uint8List bytes, String mime})?> proof(SentOrder order) async {
    final response = await _call('POST', Uri.parse('$siteBase/t/${order.timerId}/proof'),
        body: {'no': order.no, 'receipt': order.receipt});
    if (!response.ok || _privateHex == null) return null;
    try {
      return ProofCrypto.decrypt(response.body['proof'] as String, _privateHex!);
    } catch (_) {
      return null;
    }
  }

  /// Approves or rejects the proof for an order this app sent.
  Future<String?> review(SentOrder order, {required bool approve}) async {
    final response = await _call('POST', Uri.parse('$siteBase/t/${order.timerId}/review'),
        body: {'no': order.no, 'receipt': order.receipt, 'verdict': approve ? 'approve' : 'reject'});
    return response.ok ? null : (response.error ?? 'offline');
  }

  // ---- Watching ---------------------------------------------------------------------

  /// Keeps an eye on a page, and - for its timer - asks to be told when it
  /// ends. An error code, or null.
  Future<String?> watch(PublicPage page, {required bool on}) async {
    _watching.removeWhere((w) => w.kind == page.kind && w.id == page.id);
    if (on) _watching.add(WatchedPage(kind: page.kind, id: page.id, label: page.name));
    await _save();
    notifyListeners();
    final timerId = page.timerId;
    final topic = ownTopic?.call();
    if (timerId == null || topic == null || !_verified) return null;
    final response = await _call('POST', Uri.parse('$siteBase/t/$timerId/watch'),
        headers: _deviceHeaders, body: {'topic': topic, 'on': on});
    return response.ok ? null : (response.error ?? 'offline');
  }

  // ---- Plumbing -----------------------------------------------------------------------

  /// An error code, with 'verify' for "needs the one-time check first".
  String? _outcome(VisitorResponse response) {
    if (response.ok) return null;
    final error = response.error ?? 'offline';
    if (error == 'turnstile' || error == 'not-verified') {
      _verified = false;
      _save();
      notifyListeners();
      return 'verify';
    }
    return error;
  }

  Future<VisitorResponse> _call(String method, Uri url, {Map<String, String>? headers, Object? body}) async {
    try {
      return await request(method, url, headers: headers, body: body);
    } catch (e) {
      if (kDebugMode) print('PublicVisitorService: $method $url failed: $e');
      return const VisitorResponse(0, {'error': 'offline'});
    }
  }

  static String _random(int bytes) {
    final r = Random.secure();
    return List.generate(bytes, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<VisitorResponse> _overHttps(String method, Uri url, {Map<String, String>? headers, Object? body}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.openUrl(method, url).timeout(const Duration(seconds: 10));
      req.headers.contentType = ContentType.json;
      headers?.forEach(req.headers.set);
      if (body != null) req.write(jsonEncode(body));
      final res = await req.close().timeout(const Duration(seconds: 20));
      final text = await res.transform(utf8.decoder).join();
      Map<String, dynamic> decoded;
      try {
        final parsed = jsonDecode(text);
        decoded = parsed is Map ? Map<String, dynamic>.from(parsed) : {};
      } catch (_) {
        decoded = {};
      }
      return VisitorResponse(res.statusCode, decoded);
    } finally {
      client.close(force: true);
    }
  }
}
