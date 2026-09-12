import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/notifications/notification_service.dart';
import '../core/security/encryption_helper.dart';
import '../models/sync_message.dart';

/// Firebase Cloud Messaging transport.
///
/// Exists because neither of the mechanisms this app already had survives a
/// dozing Android device: the foreground service gets frozen (observed running
/// for nine hours, then not ticking for the next six), and exact alarms armed
/// via `setAlarmClock` were confirmed armed and never delivered. FCM is
/// delivered by Play Services, which is exempt from Doze, so it sidesteps that
/// fight rather than trying to win it.
///
/// Receiving is Android only: `firebase_messaging` has no Windows or Linux
/// implementation, and desktop does not need one — it is never Doze-killed and
/// the existing relay serves it. Sending is not restricted, because it is a
/// plain HTTP call to the Worker and the director in the case this exists to
/// fix runs on Windows.
class PushService {
  /// Deployed Cloudflare Worker that holds the FCM service-account credential.
  /// The credential deliberately does not ship in the app.
  static const String workerBaseUrl = 'https://subtask-push.howard-murdock.workers.dev';

  /// Last token we successfully registered, so an unchanged token on every
  /// launch does not cost a Worker request.
  static const String _registeredTokenKey = 'push_registered_token_v1';
  static const String _registeredTopicKey = 'push_registered_topic_v1';

  /// Surfaced in the diagnostics panel. A device that has silently stopped
  /// receiving looks identical to a quiet one without this.
  static const String statusKey = 'push_status_v1';

  /// Message ids the background isolate has already raised a notification for.
  ///
  /// When the app is dead, nothing drains the queue, so the background handler
  /// has to announce the directive itself. When the app is merely backgrounded
  /// the drain is still running and announces it too — so without this the same
  /// directive would be announced twice, which is a bug this project has
  /// already fixed once for scheduled alarms.
  static const String announcedByPushKey = 'push_announced_ids_v1';
  static const int _maxAnnouncedIds = 100;

  /// Whether this platform can *receive* pushes. Registration and the Firebase
  /// SDK are Android-only.
  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// Whether this platform can *send* through the Worker.
  ///
  /// Sending is a plain HTTP POST and has nothing to do with the Firebase SDK,
  /// so it must not inherit the Android restriction: the director in the case
  /// this whole change exists to fix runs on Windows.
  static bool get canSend => !kIsWeb;

  static bool _initialised = false;

  /// Brings Firebase up and registers this device against [topic].
  ///
  /// [topic] is the already-hashed pairing code the app uses for relay topics,
  /// so the Worker never learns a raw pairing code.
  static Future<void> init({required String topic}) async {
    if (!isSupported) return;
    try {
      if (!_initialised) {
        await Firebase.initializeApp();
        FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);
        _initialised = true;
      }

      final messaging = FirebaseMessaging.instance;

      // Android 13+ requires runtime notification permission. The app already
      // requests it via flutter_local_notifications, but asking through
      // Firebase as well keeps the token valid if that path was declined and
      // later granted in system settings.
      await messaging.requestPermission();

      final token = await messaging.getToken();
      if (token != null) await _registerIfChanged(token: token, topic: topic);

      // Tokens rotate on reinstall, restore, and at Google's discretion. A
      // rotation we fail to notice means this device silently stops receiving.
      messaging.onTokenRefresh.listen((fresh) {
        _registerIfChanged(token: fresh, topic: topic, force: true);
      });

      // Foreground arrivals still come through here rather than the background
      // handler, so they need the same routing.
      FirebaseMessaging.onMessage.listen((message) {
        _enqueue(message.data);
      });
    } catch (e) {
      await _recordStatus('init failed: $e');
      if (kDebugMode) print('PushService.init error: $e');
    }
  }

  /// Re-registers when the pairing code changes, which re-points delivery at
  /// the new topic.
  static Future<void> updateTopic(String topic) async {
    if (!isSupported || !_initialised) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) {
        await _registerIfChanged(token: token, topic: topic, force: true);
      }
    } catch (e) {
      await _recordStatus('topic update failed: $e');
    }
  }

  static Future<void> _registerIfChanged({
    required String token,
    required String topic,
    bool force = false,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      if (!force &&
          prefs.getString(_registeredTokenKey) == token &&
          prefs.getString(_registeredTopicKey) == topic) {
        return; // Already registered under this exact pairing.
      }

      final response = await _post('/register', {
        'topic': topic,
        'token': token,
        'platform': 'android',
      });

      if (response == 200) {
        await prefs.setString(_registeredTokenKey, token);
        await prefs.setString(_registeredTopicKey, topic);
        await _recordStatus('registered');
      } else {
        await _recordStatus('register failed: HTTP $response');
      }
    } catch (e) {
      await _recordStatus('register error: $e');
    }
  }

  /// Publishes [payload] to whichever devices hold [topic].
  ///
  /// Returns false when the Worker reports nobody registered, which is the
  /// normal answer for a desktop target or one that has not upgraded. The
  /// caller must treat that as "use the relay instead", not as a failure.
  static Future<bool> send({
    required String topic,
    required String payload,
    String kind = 'sync',
  }) async {
    if (!canSend) return false;
    try {
      final status = await _post('/send', {
        'topic': topic,
        'payload': payload,
        'kind': kind,
      });
      if (status == 200) return true;
      if (status == 404) return false; // no Android device on this topic
      await _recordStatus('send failed: HTTP $status');
      return false;
    } catch (e) {
      await _recordStatus('send error: $e');
      return false;
    }
  }

  static Future<int> _post(String path, Map<String, dynamic> body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client
          .postUrl(Uri.parse('$workerBaseUrl$path'))
          .timeout(const Duration(seconds: 10));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close().timeout(const Duration(seconds: 15));
      await response.drain<void>();
      return response.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _recordStatus(String status) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          statusKey, '${DateTime.now().toIso8601String()} | $status');
    } catch (_) {}
  }

  /// Last registration or send outcome, for the diagnostics panel.
  static Future<String> lastStatus() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return prefs.getString(statusKey) ?? 'never registered';
    } catch (_) {
      return 'unavailable';
    }
  }

  /// Whether the background isolate already notified about this message.
  static Future<bool> wasAnnouncedByPush(String messageId) async {
    if (messageId.isEmpty) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return (prefs.getStringList(announcedByPushKey) ?? const <String>[])
          .contains(messageId);
    } catch (_) {
      return false; // Fail open: a duplicate beats a silent directive.
    }
  }

  static Future<void> _markAnnouncedByPush(String messageId) async {
    if (messageId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final ids = List<String>.from(
          prefs.getStringList(announcedByPushKey) ?? const <String>[]);
      if (ids.contains(messageId)) return;
      ids.add(messageId);
      if (ids.length > _maxAnnouncedIds) {
        ids.removeRange(0, ids.length - _maxAnnouncedIds);
      }
      await prefs.setStringList(announcedByPushKey, ids);
    } catch (_) {}
  }

  /// Raises a notification from the background isolate.
  ///
  /// Decryption happens here, on the device, rather than having the sender put
  /// a readable title in the push. The payload is ciphertext precisely so that
  /// neither Cloudflare nor Google ever learns what a directive says, and a
  /// notification title would have given that away for the sake of convenience.
  static Future<void> _announceFromBackground(Map<String, dynamic> data) async {
    final raw = data['p'];
    if (raw is! String || raw.isEmpty) return;
    try {
      // This isolate is spawned fresh with none of the app's state, so the
      // notification plugin has never been set up here. showOrderDispatched
      // does not initialise it on demand the way the alarm path does, and an
      // uninitialised plugin fails quietly - which would look exactly like the
      // bug being fixed. init() is idempotent.
      await NotificationService.init();

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      // Same candidate secrets the relay path tries, in the same order.
      final secrets = <String>[];
      final own = prefs.getString('pairing_secret') ?? '';
      if (own.isNotEmpty) secrets.add(own);
      final rawContacts = prefs.getString('partner_contacts_list') ??
          prefs.getString('partner_contacts_v1');
      if (rawContacts != null && rawContacts.isNotEmpty) {
        try {
          for (final c in jsonDecode(rawContacts) as List) {
            final s = (c is Map ? c['pairingSecret'] as String? : null) ?? '';
            if (s.isNotEmpty && !secrets.contains(s)) secrets.add(s);
          }
        } catch (_) {}
      }

      SyncMessage? message;
      try {
        message = SyncMessage.decode(raw);
      } catch (_) {
        for (final secret in secrets) {
          try {
            message = SyncMessage.decode(EncryptionHelper.decryptString(raw, secret));
            break;
          } catch (_) {}
        }
      }
      if (message == null) return;

      switch (message.type) {
        case SyncMessageType.dispatchOrder:
          final order = message.payload['order'];
          final title = (order is Map ? order['title'] as String? : null) ?? 'New Directive';
          final description =
              (order is Map ? order['description'] as String? : null) ?? '';
          final tokens = (order is Map ? (order['rewardTokens'] as num?)?.toInt() : null);
          await NotificationService.showOrderDispatchedNotification(
            title: title,
            description: description,
            assignerName: message.payload['senderName'] as String? ?? 'Director',
            rewardTokens: tokens,
          );
          break;
        case SyncMessageType.chatMessage:
          await NotificationService.showChatMessageNotification(
            senderName: message.payload['senderName'] as String? ?? 'Partner',
            messageText: message.payload['text'] as String? ?? 'New message',
          );
          break;
        default:
          // Everything else is applied silently when the app next opens; only
          // arrivals a user would want to know about immediately warrant a
          // notification from here.
          return;
      }

      await _markAnnouncedByPush(message.id);
    } catch (e) {
      if (kDebugMode) print('PushService._announceFromBackground error: $e');
    }
  }

  /// Hands a received push to the UI isolate.
  ///
  /// Deliberately does nothing else. The message is the same encrypted
  /// `SyncMessage` the relay carries, and `pending_background_messages_v1` is
  /// the queue `SyncService.processPendingBackgroundMessages` already drains —
  /// so an FCM-delivered directive takes the identical path as a relay-delivered
  /// one and inherits addressing, dedup and the occurrence ledger rather than
  /// needing its own copy of that logic.
  static Future<void> _enqueue(Map<String, dynamic> data) async {
    final payload = data['p'];
    if (payload is! String || payload.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final queue = List<String>.from(
          prefs.getStringList('pending_background_push_v1') ?? const <String>[]);
      queue.add(payload);
      // Cap it: a device offline for a long stretch should not accumulate an
      // unbounded backlog to replay on next launch.
      if (queue.length > 100) queue.removeRange(0, queue.length - 100);
      await prefs.setStringList('pending_background_push_v1', queue);
    } catch (e) {
      if (kDebugMode) print('PushService._enqueue error: $e');
    }
  }
}

/// Entry point for messages that arrive while the app is backgrounded or dead.
///
/// Must be top-level and annotated: Android spawns a fresh Dart isolate to run
/// it, with none of the app's state available. It does the minimum — decode,
/// queue — and leaves every decision to the UI isolate.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } catch (_) {
    // Already initialised in this isolate; harmless.
  }
  await PushService._enqueue(message.data);

  // The queue alone is not enough. With the app swiped away there is no UI
  // isolate to drain it, so nothing would be seen until the app was next
  // opened - the push arrived and sat silently, which is precisely the failure
  // this transport was adopted to end.
  await PushService._announceFromBackground(message.data);
}
