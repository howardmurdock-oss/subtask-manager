import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/security/encryption_helper.dart';
import '../core/notifications/notification_service.dart';
import '../models/sync_message.dart';
import '../models/order_item.dart';
import '../models/order_pack.dart';
import '../models/scheduled_order_rule.dart';
import 'storage_service.dart';

// ---------------------------------------------------------------------------
// Background isolate entry point — must be top-level & annotated
// ---------------------------------------------------------------------------
@pragma('vm:entry-point')
void startBackgroundSyncCallback() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(DirectiveSyncTaskHandler());
}

// ---------------------------------------------------------------------------
// Self-contained, WebSocket-driven Background Task Handler
//
// Key improvements:
//   • Persistent WebSocket connection (0 HTTP polling requests -> NO HTTP 429!).
//   • Ongoing service notification is SILENT (LOW importance, no vibration/chime).
//   • Directives & messages trigger high-priority alerts via NotificationService.
//   • Multi-topic subscription in a single stream.
//   • Watchdog reconnects automatically on network drops.
// ---------------------------------------------------------------------------
class DirectiveSyncTaskHandler extends TaskHandler {
  final HttpClient _httpClient = HttpClient();
  WebSocket? _socket;
  StreamSubscription? _socketSub;
  Timer? _reconnectTimer;
  
  String _deviceId = '';
  String _pairingCode = '';
  String _pairingSecret = '';
  String _customRelayHost = 'ntfy.envs.net';
  String _role = '';
  Set<String> _processedIds = {};
  List<String> _partnerSecrets = [];
  List<String> _partnerCodes = [];
  Set<String> _handledPairings = {};
  Set<String> _handledDirectives = {};
  Set<String> _pastPairingCodes = {};
  
  int _msgCount = 0;
  String _connectionState = 'Initializing';
  String _lastError = 'None';
  String _lastMsgTime = 'None';

  DirectiveSyncTaskHandler() {
    _httpClient.badCertificateCallback = (cert, host, port) => true;
  }

  static String _cleanCode(String code) =>
      code.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  bool _isOwnMessage(SyncMessage? msg) {
    if (msg == null) return false;
    if (_deviceId.isNotEmpty && msg.senderId == _deviceId) return true;
    if (_deviceId.isNotEmpty && msg.payload['senderId'] == _deviceId) return true;
    final senderCode = msg.payload['senderCode'] as String?;
    if (senderCode != null && senderCode.isNotEmpty) {
      final clean = _cleanCode(senderCode);
      if (clean.isNotEmpty) {
        if (_pastPairingCodes.contains(clean) || clean == _cleanCode(_pairingCode)) {
          return true;
        }
      }
    }
    return false;
  }

  // Topic hash identical to SyncService
  static String _hashTopic(String code) {
    final bytes = utf8.encode('orders_relay_channel_v1_${code.trim().toUpperCase()}');
    final digest = sha256.convert(bytes);
    return 'orders_relay_${digest.toString().substring(0, 24)}';
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    WidgetsFlutterBinding.ensureInitialized();
    _httpClient.badCertificateCallback = (cert, host, port) => true;
    
    try {
      await NotificationService.init();
    } catch (_) {}

    await _loadConfig();
    await _connectWebSocket();
    await _saveDiagnostics();
  }

  @override
  void onRepeatEvent(DateTime timestamp) async {
    // 1. Watchdog: ensure WebSocket is alive
    if (_socket == null) {
      await _loadConfig();
      await _connectWebSocket();
    }

    // 2. Fallback poll (every 15s) to guarantee arrival even if socket was asleep
    if (_pairingCode.isNotEmpty) {
      try {
        final topics = <String>{_hashTopic(_pairingCode)};
        for (final pc in _partnerCodes) {
          if (pc.isNotEmpty) topics.add(_hashTopic(pc));
        }
        final combinedTopics = topics.join(',');
        final url = Uri.parse('https://$_customRelayHost/$combinedTopics/json?poll=1&since=2m');
        final req = await _httpClient.getUrl(url).timeout(const Duration(seconds: 5));
        final res = await req.close().timeout(const Duration(seconds: 5));
        if (res.statusCode == 200) {
          final lines = await res.transform(utf8.decoder).transform(const LineSplitter()).toList();
          for (final line in lines) {
            if (line.trim().isEmpty) continue;
            try {
              final parsed = jsonDecode(line);
              if (parsed is Map && parsed['event'] == 'message') {
                if (parsed['attachment'] is Map && parsed['attachment']['url'] != null) {
                  final fileUrl = parsed['attachment']['url'] as String;
                  final aReq = await _httpClient.getUrl(Uri.parse(fileUrl));
                  final aRes = await aReq.close();
                  final raw = await utf8.decodeStream(aRes);
                  _processIncomingRaw(raw);
                  continue;
                }
                final raw = parsed['message'] as String?;
                if (raw != null) {
                  _processIncomingRaw(raw);
                }
              }
            } catch (_) {}
          }
        }
      } catch (_) {}
    }

    // 3. Process due scheduled rules in the background
    await _checkScheduledRules();

    await _saveDiagnostics();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _reconnectTimer?.cancel();
    await _socketSub?.cancel();
    await _socket?.close();
    _socket = null;
    _httpClient.close(force: true);
  }

  // ---- Config Loading ----

  Future<void> _loadConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      _deviceId = prefs.getString('pairing_device_id') ?? '';
      _pairingCode = prefs.getString('pairing_code') ?? '';
      _pairingSecret = prefs.getString('pairing_secret') ?? '';
      _customRelayHost = prefs.getString('pairing_custom_relay') ?? 'ntfy.envs.net';
      if (_customRelayHost.isEmpty) _customRelayHost = 'ntfy.envs.net';
      _role = prefs.getString('pairing_role') ?? '';

      final savedIdsV2 = prefs.getStringList('processed_sync_message_ids_v2');
      if (savedIdsV2 != null) {
        _processedIds.addAll(savedIdsV2);
      }
      final savedSyncIds = prefs.getStringList('processed_sync_message_ids');
      if (savedSyncIds != null) {
        _processedIds.addAll(savedSyncIds);
      }
      final savedIds = prefs.getStringList('bg_processed_message_ids');
      if (savedIds != null) {
        _processedIds.addAll(savedIds);
      }

      final savedPastCodes = prefs.getStringList('past_pairing_codes_v1');
      if (savedPastCodes != null) {
        _pastPairingCodes = savedPastCodes.map((c) => _cleanCode(c)).toSet();
      }
      if (_pairingCode.isNotEmpty) {
        _pastPairingCodes.add(_cleanCode(_pairingCode));
      }

      final savedHandledDirectives = prefs.getStringList('handled_directive_ids_v1');
      if (savedHandledDirectives != null) {
        _handledDirectives = savedHandledDirectives.toSet();
      }

      final rawActiveOrders = prefs.getString('storage_active_orders');
      if (rawActiveOrders != null && rawActiveOrders.isNotEmpty) {
        try {
          final List list = jsonDecode(rawActiveOrders);
          for (final item in list) {
            if (item is Map) {
              final id = item['id'] as String?;
              if (id != null && id.isNotEmpty) _handledDirectives.add(id);
              final order = item['order'] as Map?;
              if (order != null) {
                final oid = order['id'] as String?;
                if (oid != null && oid.isNotEmpty) _handledDirectives.add(oid);
                final otitle = order['title'] as String?;
                if (otitle != null && otitle.trim().isNotEmpty) {
                  _handledDirectives.add('title_${otitle.trim().toLowerCase()}');
                }
              }
            }
          }
        } catch (_) {}
      }

      final rawContacts = prefs.getString('partner_contacts_list') ?? prefs.getString('partner_contacts_v1');
      if (rawContacts != null && rawContacts.isNotEmpty) {
        try {
          final List list = jsonDecode(rawContacts);
          _partnerSecrets = list
              .map((c) => (c['pairingSecret'] as String?) ?? '')
              .where((s) => s.isNotEmpty)
              .toList();
          _partnerCodes = list
              .map((c) => (c['pairingCode'] as String?) ?? '')
              .where((s) => s.isNotEmpty)
              .toList();
        } catch (_) {}
      }

      final savedHandled = prefs.getStringList('handled_pairing_request_fingerprints_v1');
      if (savedHandled != null) {
        _handledPairings = savedHandled.toSet();
      }
    } catch (e) {
      _lastError = 'Config error: $e';
    }
  }

  // ---- WebSocket Persistent Connection ----

  Future<void> _connectWebSocket() async {
    if (_pairingCode.isEmpty) {
      _connectionState = 'No Pairing Code Set';
      _updateServiceNotification('Ready to pair • Open app to configure');
      return;
    }

    try {
      await _socketSub?.cancel();
      _socketSub = null;
      await _socket?.close();
      _socket = null;

      final topics = <String>{_hashTopic(_pairingCode)};
      for (final pc in _partnerCodes) {
        if (pc.isNotEmpty) topics.add(_hashTopic(pc));
      }

      final combinedTopics = topics.join(',');
      final wsUrl = 'wss://$_customRelayHost/$combinedTopics/ws?since=2h';

      _connectionState = 'Connecting to $_customRelayHost...';
      final socket = await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 10));
      _socket = socket;
      _connectionState = 'Connected ($_customRelayHost)';
      _lastError = 'None';

      _updateServiceNotification('Listening for directives & sync updates');

      _socketSub = _socket!.listen(
        (data) async {
          try {
            final parsed = jsonDecode(data.toString());
            if (parsed is Map && parsed['event'] == 'message') {
              if (parsed['attachment'] is Map && parsed['attachment']['url'] != null) {
                final fileUrl = parsed['attachment']['url'] as String;
                final req = await _httpClient.getUrl(Uri.parse(fileUrl));
                final res = await req.close();
                final raw = await utf8.decodeStream(res);
                _processIncomingRaw(raw);
                return;
              }
              final raw = parsed['message'] as String?;
              if (raw != null) {
                _processIncomingRaw(raw);
              }
            }
          } catch (e) {
            _lastError = 'Frame decode: $e';
          }
        },
        onError: (err) {
          _connectionState = 'Connection Error';
          _lastError = 'Socket error: $err';
          _socket = null;
          _scheduleReconnect();
        },
        onDone: () {
          _connectionState = 'Disconnected (Auto-reconnecting)';
          _socket = null;
          _scheduleReconnect();
        },
      );
    } catch (e) {
      _connectionState = 'Connect Failed';
      _lastError = 'Connect error: $e';
      _socket = null;
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 10), () async {
      await _loadConfig();
      await _connectWebSocket();
      await _saveDiagnostics();
    });
  }

  // ---- Message Processing & High Priority Alert Triggering ----

  SyncMessage? _tryDecode(String raw) {
    // 1. Plain JSON
    try {
      final msg = SyncMessage.decode(raw);
      if (!_isOwnMessage(msg)) return msg;
    } catch (_) {}

    // 2. Own secret
    if (_pairingSecret.isNotEmpty) {
      try {
        final plain = EncryptionHelper.decryptString(raw, _pairingSecret);
        final msg = SyncMessage.decode(plain);
        if (!_isOwnMessage(msg)) return msg;
      } catch (_) {}
    }

    // 3. Partner secrets
    for (final sec in _partnerSecrets) {
      try {
        final plain = EncryptionHelper.decryptString(raw, sec);
        final msg = SyncMessage.decode(plain);
        if (!_isOwnMessage(msg)) return msg;
      } catch (_) {}
    }

    return null;
  }

  void _processIncomingRaw(String raw) async {
    SyncMessage? message = _tryDecode(raw);

    // If decoding failed, reload latest config from disk and retry
    if (message == null) {
      await _loadConfig();
      message = _tryDecode(raw);
    }

    if (message == null || _isOwnMessage(message)) return;
    if (message.id.isNotEmpty && _processedIds.contains(message.id)) return;

    if (message.id.isNotEmpty) {
      _processedIds.add(message.id);
      _persistProcessedIds();
    }

    _msgCount++;
    final now = DateTime.now();
    _lastMsgTime = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

    _handleBackgroundMessage(message);
    _saveDiagnostics();
  }

  void _persistProcessedIds() {
    SharedPreferences.getInstance().then((prefs) {
      prefs.setStringList('processed_sync_message_ids_v2', _processedIds.toList());
      prefs.setStringList('bg_processed_message_ids', _processedIds.toList());
      prefs.setStringList('processed_sync_message_ids', _processedIds.toList());
    }).catchError((_) {});
  }

  bool _isDirectiveHandled({String? activeOrderId, String? orderId, String? msgId, String? title}) {
    if (activeOrderId != null && activeOrderId.isNotEmpty && _handledDirectives.contains(activeOrderId)) {
      return true;
    }
    if (orderId != null && orderId.isNotEmpty && _handledDirectives.contains(orderId)) {
      return true;
    }
    if (msgId != null && msgId.isNotEmpty && _handledDirectives.contains(msgId)) {
      return true;
    }
    if (title != null && title.trim().isNotEmpty) {
      final cleanTitle = 'title_${title.trim().toLowerCase()}';
      if (_handledDirectives.contains(cleanTitle)) {
        return true;
      }
    }
    return false;
  }

  void _markDirectiveHandled({String? activeOrderId, String? orderId, String? msgId, String? title}) {
    bool changed = false;
    if (activeOrderId != null && activeOrderId.isNotEmpty && !_handledDirectives.contains(activeOrderId)) {
      _handledDirectives.add(activeOrderId);
      changed = true;
    }
    if (orderId != null && orderId.isNotEmpty && !_handledDirectives.contains(orderId)) {
      _handledDirectives.add(orderId);
      changed = true;
    }
    if (msgId != null && msgId.isNotEmpty && !_handledDirectives.contains(msgId)) {
      _handledDirectives.add(msgId);
      changed = true;
    }
    if (title != null && title.trim().isNotEmpty) {
      final cleanTitle = 'title_${title.trim().toLowerCase()}';
      if (!_handledDirectives.contains(cleanTitle)) {
        _handledDirectives.add(cleanTitle);
        changed = true;
      }
    }
    if (changed) {
      if (_handledDirectives.length > 500) {
        _handledDirectives.remove(_handledDirectives.first);
      }
      SharedPreferences.getInstance().then((prefs) {
        prefs.setStringList('handled_directive_ids_v1', _handledDirectives.toList());
      }).catchError((_) {});
    }
  }

  void _queuePendingOrder(Map<String, dynamic> payload) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final list = prefs.getStringList('pending_background_orders_v1') ?? [];
      list.add(jsonEncode(payload));
      await prefs.setStringList('pending_background_orders_v1', list);
    } catch (_) {}
  }

  void _queuePendingChat(Map<String, dynamic> payload) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final list = prefs.getStringList('pending_background_chats_v1') ?? [];
      list.add(jsonEncode(payload));
      await prefs.setStringList('pending_background_chats_v1', list);
    } catch (_) {}
  }

  void _queuePendingReview(Map<String, dynamic> payload) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final list = prefs.getStringList('pending_background_reviews_v1') ?? [];
      list.add(jsonEncode(payload));
      await prefs.setStringList('pending_background_reviews_v1', list);
    } catch (_) {}
  }

  void _queuePendingPairing(Map<String, dynamic> payload) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final list = prefs.getStringList('pending_background_pairings_v1') ?? [];
      list.add(jsonEncode(payload));
      await prefs.setStringList('pending_background_pairings_v1', list);
    } catch (_) {}
  }

  void _queuePendingQuest(Map<String, dynamic> payload) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final list = prefs.getStringList('pending_background_quests_v1') ?? [];
      list.add(jsonEncode(payload));
      await prefs.setStringList('pending_background_quests_v1', list);
    } catch (_) {}
  }

  void _updateServiceNotification(String text) {
    try {
      FlutterForegroundTask.updateService(
        notificationTitle: '(sub)Task Manager Link Active',
        notificationText: text,
      );
    } catch (_) {}
  }

  Future<void> _checkScheduledRules() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final savedRulesJson = prefs.getString('saved_scheduled_rules_v1');
      if (savedRulesJson == null || savedRulesJson.isEmpty) return;

      final List list = jsonDecode(savedRulesJson);
      final rules = list
          .map((r) => ScheduledOrderRule.fromJson(Map<String, dynamic>.from(r as Map)))
          .toList();
      final now = DateTime.now();
      bool hasUpdates = false;

      for (int i = 0; i < rules.length; i++) {
        final rule = rules[i];
        if (!rule.isEnabled) continue;

        if (now.isAfter(rule.nextTriggerTime) || now.isAtSameMomentAs(rule.nextTriggerTime)) {
          // Prevent rapid duplicate triggers if checked in consecutive repeat events
          if (rule.lastTriggeredAt != null && now.difference(rule.lastTriggeredAt!).inSeconds < 45) {
            continue;
          }

          await _executeBackgroundScheduledRule(rule, prefs);

          final nextRecurrence = rule.computeNextRecurrence(now);
          if (nextRecurrence != null) {
            final nextStaged = _drawBackgroundCandidateOrder(rule, prefs);
            rules[i] = rule.copyWith(
              lastTriggeredAt: now,
              nextTriggerTime: nextRecurrence,
              stagedOrder: nextStaged,
            );
            // Arm native OS exact alarm for next recurrence
            NotificationService.scheduleOrderNotification(rules[i]);
          } else {
            rules[i] = rule.copyWith(
              lastTriggeredAt: now,
              isEnabled: false,
              clearStagedOrder: true,
            );
            NotificationService.cancelOrderNotification(rule.id);
          }
          hasUpdates = true;
        }
      }

      if (hasUpdates) {
        final encoded = jsonEncode(rules.map((r) => r.toJson()).toList());
        await prefs.setString('saved_scheduled_rules_v1', encoded);
      }
    } catch (e) {
      if (kDebugMode) print('BackgroundLinkService: scheduled rule check error: $e');
    }
  }

  OrderItem? _drawBackgroundCandidateOrder(ScheduledOrderRule rule, SharedPreferences prefs) {
    if (rule.isSpecificOrder && rule.specificOrder != null) {
      return rule.specificOrder;
    }

    List<OrderPack> packs = [];
    try {
      final rawPacks = prefs.getString('storage_order_packs');
      if (rawPacks != null && rawPacks.isNotEmpty) {
        final List packList = jsonDecode(rawPacks);
        packs = packList
            .map((p) => OrderPack.fromJson(Map<String, dynamic>.from(p as Map)))
            .toList();
      }
    } catch (_) {}

    if (packs.isEmpty) {
      packs = StorageService.getDefaultPacks();
    }

    final ownedList = prefs.getStringList('storage_owned_equipment') ?? [];
    final ownedEquipment = ownedList
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toSet();

    final catFilter = (rule.categoryFilter == null ||
            rule.categoryFilter!.isEmpty ||
            rule.categoryFilter!.trim().toLowerCase() == 'all')
        ? null
        : rule.categoryFilter!.trim().toLowerCase();

    final candidates = <OrderItem>[];
    for (final pack in packs.where((p) => p.isEnabled)) {
      for (final order in pack.orders) {
        if (!order.allowRandomDraw) continue;

        if (catFilter != null && order.category.trim().toLowerCase() != catFilter) {
          continue;
        }

        if (order.tier < rule.minTier || order.tier > rule.maxTier) {
          continue;
        }

        if (order.requiredEquipment.isNotEmpty) {
          final hasMissing = order.requiredEquipment.any(
            (eq) => !ownedEquipment.contains(eq.trim().toLowerCase()),
          );
          if (hasMissing) continue;
        }

        candidates.add(order);
      }
    }

    if (candidates.isEmpty) {
      for (final pack in packs.where((p) => p.isEnabled)) {
        for (final order in pack.orders) {
          if (!order.allowRandomDraw) continue;
          if (order.tier >= rule.minTier && order.tier <= rule.maxTier) {
            candidates.add(order);
          }
        }
      }
    }

    if (candidates.isEmpty) {
      for (final pack in packs.where((p) => p.isEnabled)) {
        for (final order in pack.orders) {
          if (order.allowRandomDraw) {
            candidates.add(order);
          }
        }
      }
    }

    if (candidates.isEmpty) {
      final defaultPacks = StorageService.getDefaultPacks();
      candidates.addAll(defaultPacks.expand((p) => p.orders));
    }

    if (candidates.isNotEmpty) {
      return candidates[Random().nextInt(candidates.length)];
    }
    return null;
  }

  Future<void> _executeBackgroundScheduledRule(ScheduledOrderRule rule, SharedPreferences prefs) async {
    final finalOrder = rule.stagedOrder ?? rule.specificOrder ?? _drawBackgroundCandidateOrder(rule, prefs);
    if (finalOrder == null) return;

    if (rule.targetType == ScheduleTargetType.playerSelfDraw) {
      // Queue order for main app OrderEngine with scheduled window arrival timestamp
      final payload = {
        'type': 'dispatchOrder',
        'order': finalOrder.toJson(),
        'senderName': 'Scheduled Task',
        'senderId': '__self__',
        'senderCode': '',
        'assignedByDirector': false,
        'assignedAt': rule.nextTriggerTime.toIso8601String(),
      };
      _queuePendingOrder(payload);

      // High priority alert with sound, vibration, and banner
      NotificationService.showOrderDispatchedNotification(
        title: finalOrder.title,
        description: finalOrder.description,
        assignerName: 'Scheduled Task',
        rewardTokens: finalOrder.rewardTokens,
      );
    } else if (rule.targetType == ScheduleTargetType.directorDispatch) {
      final isSelf = rule.targetPartnerId == '__self__' || rule.targetPartnerName == 'Myself (This Device)';
      if (isSelf) {
        final payload = {
          'type': 'dispatchOrder',
          'order': finalOrder.toJson(),
          'senderName': 'Myself (Director)',
          'senderId': '__self__',
          'senderCode': '',
          'assignedByDirector': true,
          'assignedAt': rule.nextTriggerTime.toIso8601String(),
        };
        _queuePendingOrder(payload);

        NotificationService.showOrderDispatchedNotification(
          title: finalOrder.title,
          description: finalOrder.description,
          assignerName: 'Director Schedule (Self)',
          rewardTokens: finalOrder.rewardTokens,
        );
      } else if (rule.targetPartnerCode != null && rule.targetPartnerCode!.isNotEmpty) {
        // Dispatch over HTTP relay to submissive partner
        try {
          final targetTopic = _hashTopic(rule.targetPartnerCode!);
          final syncMsg = SyncMessage(
            id: 'sched_${DateTime.now().millisecondsSinceEpoch}',
            type: SyncMessageType.dispatchOrder,
            senderId: _deviceId,
            payload: {
              'order': finalOrder.toJson(),
              'senderCode': _pairingCode,
              'senderName': 'Director',
              'senderId': _deviceId,
              'assignedByDirector': true,
              'assignedAt': rule.nextTriggerTime.toIso8601String(),
            },
          );

          String outPayload = syncMsg.encode();
          final idx = _partnerCodes.indexOf(rule.targetPartnerCode!);
          if (idx >= 0 && idx < _partnerSecrets.length && _partnerSecrets[idx].isNotEmpty) {
            outPayload = EncryptionHelper.encryptString(outPayload, _partnerSecrets[idx]);
          } else if (_pairingSecret.isNotEmpty) {
            outPayload = EncryptionHelper.encryptString(outPayload, _pairingSecret);
          }

          final url = Uri.parse('https://$_customRelayHost/$targetTopic');
          final req = await _httpClient.postUrl(url);
          req.headers.contentType = ContentType.text;
          req.write(outPayload);
          await req.close();

          NotificationService.showGenericNotification(
            title: '⚡ Scheduled Directive Dispatched',
            body: 'Dispatched "${finalOrder.title}" to ${rule.targetPartnerName ?? "Partner"}.',
          );
        } catch (e) {
          if (kDebugMode) print('Background dispatch error: $e');
        }
      }
    }
  }

  void _handleBackgroundMessage(SyncMessage msg) {
    if (_isOwnMessage(msg)) return;
    try {
      switch (msg.type) {
        case SyncMessageType.dispatchOrder:
          final rawOrder = msg.payload['order'];
          final Map<String, dynamic> orderData = (rawOrder is Map)
              ? Map<String, dynamic>.from(rawOrder)
              : <String, dynamic>{};
          final title = orderData['title'] as String? ?? 'New Directive';
          final desc = orderData['description'] as String? ?? 'You have received a new directive.';
          final senderName = msg.payload['senderName'] as String? ?? 'Director';
          final tokens = (orderData['rewardTokens'] as num?)?.toInt();
          final activeOrderId = msg.payload['activeOrderId'] as String?;
          final orderId = orderData['id'] as String?;

          final isResend = msg.payload['isResend'] == true || msg.payload['forceAssign'] == true;

          // Check if directive was already handled or recorded in active orders / handled IDs (bypass if intentional re-send)
          if (!isResend && _isDirectiveHandled(activeOrderId: activeOrderId, orderId: orderId, msgId: msg.id, title: title)) {
            break;
          }
          _markDirectiveHandled(activeOrderId: activeOrderId, orderId: orderId, msgId: msg.id, title: title);

          final queuedPayload = Map<String, dynamic>.from(msg.payload);
          queuedPayload['messageId'] = msg.id;

          // Queue order for main app OrderEngine
          _queuePendingOrder(queuedPayload);

          // High priority alert with sound, vibration, and banner
          NotificationService.showOrderDispatchedNotification(
            title: title,
            description: desc,
            assignerName: senderName,
            rewardTokens: tokens,
          );
          break;

        case SyncMessageType.orderStatusUpdate:
          final statusStr = msg.payload['status'] as String?;
          final orderTitle = msg.payload['orderTitle'] as String? ?? 'Directive';
          final senderName = msg.payload['senderName'] as String? ?? 'Player';
          if (statusStr == 'emergencyCleared' || statusStr == 'cleared') {
            NotificationService.showGenericNotification(
              title: 'Directive Emergency Cleared',
              body: '$senderName emergency-cleared "$orderTitle".',
            );
          } else if (statusStr == 'failed') {
            final reason = msg.payload['reason'] as String?;
            NotificationService.showOrderFailedNotification(
              title: orderTitle,
              playerName: senderName,
              reason: reason,
            );
          }
          break;

        case SyncMessageType.approveProof:
          final orderTitle = msg.payload['orderTitle'] as String? ?? 'Your directive';
          final tokens = (msg.payload['rewardTokens'] as num?)?.toInt() ?? 0;
          final senderName = msg.payload['senderName'] as String? ?? 'Director';

          _queuePendingReview(msg.payload);

          NotificationService.showProofReviewedNotification(
            title: orderTitle,
            approved: true,
            tokensAwarded: tokens,
            reviewerName: senderName,
          );
          break;

        case SyncMessageType.rejectProof:
          final orderTitle = msg.payload['orderTitle'] as String? ?? 'Your directive';
          final senderName = msg.payload['senderName'] as String? ?? 'Director';
          final returnToQueue = msg.payload['returnToQueue'] == true;

          _queuePendingReview(msg.payload);

          NotificationService.showProofReviewedNotification(
            title: orderTitle,
            approved: false,
            reviewerName: returnToQueue ? '$senderName (Returned to Queue - Try Again)' : '$senderName (Rejected & Penalized)',
          );
          break;

        case SyncMessageType.chatMessage:
          final senderName = msg.payload['senderName'] as String? ?? 'Partner';
          final text = msg.payload['text'] as String? ?? 'New message received';

          _queuePendingChat(msg.payload);

          NotificationService.showChatMessageNotification(
            senderName: senderName,
            messageText: text,
          );
          break;

        case SyncMessageType.pairingRequest:
          final senderName = msg.payload['senderName'] as String? ?? 'Partner';
          final senderCode = msg.payload['senderCode'] as String? ?? '';
          final senderId = msg.payload['senderId'] as String? ?? msg.senderId;
          final sharedSecret = msg.payload['sharedSecret'] as String? ?? '';

          final cleanSender = _cleanCode(senderCode);
          final isHandled = cleanSender.isNotEmpty &&
              (_handledPairings.contains(cleanSender) ||
               (sharedSecret.isNotEmpty && _handledPairings.contains('${cleanSender}_$sharedSecret')));

          // Ignore if sender is already an existing partner or self or already handled
          final isExistingPartner = isHandled ||
              _partnerCodes.any((c) => _cleanCode(c) == cleanSender) ||
              (cleanSender.isNotEmpty && cleanSender == _cleanCode(_pairingCode)) ||
              (senderId.isNotEmpty && senderId == _deviceId);

          if (isExistingPartner) {
            break;
          }

          _queuePendingPairing(msg.payload);

          NotificationService.showPairingRequestNotification(
            senderName: senderName,
            senderCode: senderCode,
          );
          break;

        case SyncMessageType.submitProof:
          if (_role != 'director') {
            break;
          }
          final rawOrder = msg.payload['activeOrder'] ?? msg.payload['order'];
          final Map<String, dynamic> orderData = (rawOrder is Map)
              ? Map<String, dynamic>.from(rawOrder)
              : <String, dynamic>{};
          final innerOrder = (orderData['order'] is Map)
              ? Map<String, dynamic>.from(orderData['order'] as Map)
              : orderData;
          final title = innerOrder['title'] as String? ?? 'Directive';
          final senderName = msg.payload['senderName'] as String? ?? 'Player';
          final isIncomplete = msg.payload['isIncompleteTimer'] as bool? ?? false;
          final secRemaining = (msg.payload['secondsRemaining'] as num?)?.toInt();

          NotificationService.showProofSubmittedNotification(
            title: title,
            senderName: senderName,
            isIncompleteTimer: isIncomplete,
            secondsRemaining: secRemaining,
          );
          break;

        case SyncMessageType.dispatchQuest:
          final rawQuest = msg.payload['quest'];
          final Map<String, dynamic> questData = (rawQuest is Map)
              ? Map<String, dynamic>.from(rawQuest)
              : <String, dynamic>{};
          final questTitle = questData['title'] as String? ?? 'New Quest Playlist';
          final senderName = msg.payload['senderName'] as String? ?? 'Director';
          final rawSteps = questData['steps'] as List? ?? [];
          final bonusTokens = (questData['bonusTokensOnComplete'] as num?)?.toInt() ?? 25;

          // Queue quest for main app QuestService
          _queuePendingQuest(msg.payload);

          // High priority alert with sound, vibration, and banner
          NotificationService.showOrderDispatchedNotification(
            title: 'Quest: $questTitle',
            description: '${rawSteps.length} chained directives assigned by $senderName. (+$bonusTokens bonus tokens)',
            assignerName: senderName,
            rewardTokens: bonusTokens,
          );
          break;

        case SyncMessageType.questStepCompleted:
          final senderName = msg.payload['senderName'] as String? ?? 'Player';
          final questTitle = msg.payload['questTitle'] as String? ?? 'Quest';
          final stepIndex = (msg.payload['stepIndex'] as num?)?.toInt() ?? 0;
          final stepTitle = msg.payload['stepTitle'] as String? ?? 'Step';
          final totalSteps = (msg.payload['totalSteps'] as num?)?.toInt() ?? 1;
          final tokens = (msg.payload['tokensAwarded'] as num?)?.toInt() ?? 0;

          NotificationService.showProofReviewedNotification(
            title: 'Step Completed: $stepTitle',
            approved: true,
            tokensAwarded: tokens,
            reviewerName: '$senderName (Step ${stepIndex + 1} of $totalSteps in "$questTitle")',
          );
          break;

        case SyncMessageType.questCompleted:
          final senderName = msg.payload['senderName'] as String? ?? 'Player';
          final questTitle = msg.payload['questTitle'] as String? ?? 'Quest';
          final bonusTokens = (msg.payload['bonusTokens'] as num?)?.toInt() ?? 0;

          NotificationService.showProofReviewedNotification(
            title: '🏆 Quest Conquered: "$questTitle"',
            approved: true,
            tokensAwarded: bonusTokens,
            reviewerName: '$senderName conquered all directives in the quest chain!',
          );
          break;

        default:
          break;
      }
    } catch (e) {
      _lastError = 'Background handler: $e';
    }
  }

  Future<void> _saveDiagnostics() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('bg_link_state', _connectionState);
      await prefs.setString('bg_link_host', _customRelayHost);
      await prefs.setString('bg_link_last_msg', _lastMsgTime);
      await prefs.setInt('bg_link_msg_count', _msgCount);
      await prefs.setString('bg_link_last_error', _lastError);
      await prefs.setString('bg_link_is_socket_live', (_socket != null).toString());
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// Public API for managing the background service
// ---------------------------------------------------------------------------
class BackgroundLinkService {
  static bool _isBatterySaver = false;
  static bool get isBatterySaver => _isBatterySaver;

  /// Dedicated SILENT channel ID for the ongoing foreground service
  static const _serviceChannelId = 'directive_link_service_v5';

  static Future<void> init() async {
    if (!Platform.isAndroid) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      _isBatterySaver = prefs.getBool('battery_saver_mode') ?? false;

      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: _serviceChannelId,
          channelName: 'Directive Background Link',
          channelDescription: 'Maintains background connection for directives and sync',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
          enableVibration: false,
          playSound: false,
          showWhen: false,
          showBadge: false,
          visibility: NotificationVisibility.VISIBILITY_PUBLIC,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(15000), // 15 second watchdog & fallback poll
          autoRunOnBoot: true,
          allowWakeLock: true,
          allowAutoRestart: true,
          stopWithTask: false,
        ),
      );

      if (!_isBatterySaver) {
        await startService();
      }
    } catch (e) {
      if (kDebugMode) print('BackgroundLinkService.init error: $e');
    }
  }

  static Future<void> setBatterySaver(bool enabled) async {
    _isBatterySaver = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('battery_saver_mode', enabled);
      if (enabled) {
        await stopService();
      } else {
        await startService();
      }
    } catch (_) {}
  }

  static Future<bool> startService() async {
    if (!Platform.isAndroid) return false;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
        await Future.delayed(const Duration(milliseconds: 400));
      }

      await FlutterForegroundTask.requestNotificationPermission();

      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }

      final result = await FlutterForegroundTask.startService(
        serviceId: 256,
        serviceTypes: [
          ForegroundServiceTypes.dataSync,
          ForegroundServiceTypes.remoteMessaging,
        ],
        notificationTitle: '(sub)Task Manager Link Active',
        notificationText: 'Listening for incoming directives & sync messages',
        callback: startBackgroundSyncCallback,
      );

      return result is ServiceRequestSuccess;
    } catch (e) {
      if (kDebugMode) print('BackgroundLinkService.startService error: $e');
      return false;
    }
  }

  static Future<bool> stopService() async {
    if (!Platform.isAndroid) return false;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        final result = await FlutterForegroundTask.stopService();
        return result is ServiceRequestSuccess;
      }
      return true;
    } catch (e) {
      if (kDebugMode) print('BackgroundLinkService.stopService error: $e');
      return false;
    }
  }

  /// Read live diagnostics saved by background isolate
  static Future<Map<String, String>> getDiagnostics() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return {
      'isRunning': (await FlutterForegroundTask.isRunningService).toString(),
      'socketLive': prefs.getString('bg_link_is_socket_live') ?? 'false',
      'state': prefs.getString('bg_link_state') ?? 'Unknown',
      'host': prefs.getString('bg_link_host') ?? 'ntfy.envs.net',
      'lastMsg': prefs.getString('bg_link_last_msg') ?? 'None',
      'msgCount': (prefs.getInt('bg_link_msg_count') ?? 0).toString(),
      'lastError': prefs.getString('bg_link_last_error') ?? 'None',
    };
  }
}
