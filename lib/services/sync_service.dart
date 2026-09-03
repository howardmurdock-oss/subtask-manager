import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/sync_message.dart';
import '../models/order_item.dart';
import '../models/order_pack.dart';
import '../models/active_order.dart';
import '../models/active_redemption.dart';
import '../models/partner_contact.dart';
import '../models/chat_message.dart';
import '../models/quest_item.dart';
import '../core/security/encryption_helper.dart';
import '../core/notifications/notification_service.dart';
import '../core/sound/sound_service.dart';
import 'order_engine.dart';
import 'partner_service.dart';
import 'chat_service.dart';
import 'quest_service.dart';

enum ConnectionRole { none, player, director }
enum ConnectionStatus { disconnected, listening, connecting, connected }
enum ConnectionTransport { cloudRelay, localWifi, directIp }

class SyncService extends ChangeNotifier {
  final OrderEngine _engine;
  PartnerService? _partnerService;
  ChatService? _chatService;
  QuestService? _questService;
  final StreamController<ActiveOrder> _incomingOrderController = StreamController<ActiveOrder>.broadcast();

  Stream<ActiveOrder> get onOrderReceived => _incomingOrderController.stream;
  QuestService? get questService => _questService;

  ConnectionRole _role = ConnectionRole.none;
  ConnectionStatus _status = ConnectionStatus.disconnected;
  ConnectionTransport _transport = ConnectionTransport.cloudRelay;
  String _statusMessage = 'Ready to pair';
  bool _autoConnect = false;

  String _deviceId = '';
  String _pairingCode = '';
  String _pairingSecret = '';
  String _nickname = '';
  String? _connectedPeerIp;
  String _customRelayHost = 'ntfy.envs.net';
  int _port = 8899;

  // Remote Submissive State (Observed by Director)
  List<ActiveOrder> _remoteActiveOrders = [];
  List<ActiveOrder> _remoteReviewOrders = [];
  /// Maps remote review order IDs to the sender's pairing code/id for routing approval responses
  final Map<String, String> _remoteReviewSenderCode = {};
  final Map<String, String> _remoteReviewSenderId = {};
  List<ActiveRedemption> _remotePendingRedemptions = [];
  int _remoteTokens = 0;
  int _remoteStreak = 0;
  /// Set of order IDs and titles confirmed to be actively mounted on submissive's dashboard
  final Set<String> _confirmedOnPlayerOrderIds = <String>{};
  /// Set of quest IDs and titles confirmed to be received by player
  final Set<String> _confirmedOnPlayerQuestIds = <String>{};

  // Local Wi-Fi / Direct IP socket
  HttpServer? _server;
  WebSocket? _socket;
  StreamSubscription? _socketSubscription;

  WebSocket? _cloudSocket;
  StreamSubscription? _cloudSubscription;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  Timer? _bgDrainTimer;
  final HttpClient _httpClient = HttpClient();
  final Set<String> _processedMessageIds = <String>{};
  final Set<String> _pastPairingCodes = <String>{};
  final Set<String> _handledDirectiveIds = <String>{};

  // Broadcast throttling to prevent relay rate-limiting
  Timer? _broadcastDebounceTimer;
  DateTime? _lastBroadcastTime;
  static const _broadcastMinInterval = Duration(seconds: 8);
  static const _broadcastDebounceDelay = Duration(seconds: 10);

  SyncService(this._engine, {PartnerService? partnerService}) : _partnerService = partnerService {
    _deviceId = generateRandomId(8);
    _pairingCode = generateRandomCode(6);
    _pairingSecret = generateRandomCode(6);

    _httpClient.connectionTimeout = const Duration(seconds: 8);
    _httpClient.idleTimeout = const Duration(seconds: 15);
    _httpClient.maxConnectionsPerHost = 20;
    _httpClient.badCertificateCallback = (X509Certificate cert, String host, int port) => true;

    // Auto-broadcast when local player engine state changes (debounced)
    _engine.addListener(_onEngineChanged);
  }

  void setAppRole(ConnectionRole role) {
    if (_role != role) {
      _role = role;
      _savePairingSettings();
      if (_role == ConnectionRole.director) {
        requestStateFromPlayer();
      } else {
        _doBroadcastNow();
      }
      notifyListeners();
    }
  }

  /// Debounced handler: waits 10s after the last engine change before broadcasting.
  /// This prevents the per-second timer ticks from flooding the relay.
  void _onEngineChanged() {
    _broadcastDebounceTimer?.cancel();
    _broadcastDebounceTimer = Timer(_broadcastDebounceDelay, () {
      _doBroadcastNow();
    });
  }

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedAuto = prefs.getBool('pairing_auto_connect') ?? false;
      final savedDeviceId = prefs.getString('pairing_device_id');
      final savedCode = prefs.getString('pairing_code');
      final savedSecret = prefs.getString('pairing_secret');
      final savedNickname = prefs.getString('pairing_nickname');
      final savedRole = prefs.getString('pairing_role');
      final savedTransport = prefs.getString('pairing_transport');
      final savedHost = prefs.getString('pairing_host_ip');
      final savedRelay = prefs.getString('pairing_custom_relay');
      final savedPort = prefs.getInt('pairing_port');

      if (savedDeviceId != null && savedDeviceId.isNotEmpty) {
        _deviceId = savedDeviceId;
      } else {
        await prefs.setString('pairing_device_id', _deviceId);
      }
      if (savedCode != null && savedCode.isNotEmpty) {
        _pairingCode = savedCode;
      } else {
        await prefs.setString('pairing_code', _pairingCode);
      }
      if (savedSecret != null && savedSecret.isNotEmpty) {
        _pairingSecret = savedSecret;
      } else {
        await prefs.setString('pairing_secret', _pairingSecret);
      }
      if (savedNickname != null) _nickname = savedNickname;
      if (savedHost != null) _connectedPeerIp = savedHost;
      if (savedRelay != null && savedRelay.isNotEmpty && savedRelay != 'ntfy.sh') {
        _customRelayHost = savedRelay;
      } else {
        _customRelayHost = 'ntfy.envs.net';
      }
      await prefs.setString('pairing_custom_relay', _customRelayHost);
      if (savedPort != null) _port = savedPort;

      if (savedTransport != null) {
        _transport = ConnectionTransport.values.firstWhere(
          (e) => e.name == savedTransport,
          orElse: () => ConnectionTransport.cloudRelay,
        );
      }

      if (savedRole != null) {
        _role = ConnectionRole.values.firstWhere(
          (e) => e.name == savedRole,
          orElse: () => ConnectionRole.none,
        );
      }

      final savedProcessedIdsV2 = prefs.getStringList('processed_sync_message_ids_v2');
      if (savedProcessedIdsV2 != null) {
        _processedMessageIds.addAll(savedProcessedIdsV2);
      }
      final savedProcessedIds = prefs.getStringList('processed_sync_message_ids');
      if (savedProcessedIds != null) {
        _processedMessageIds.addAll(savedProcessedIds);
      }
      final bgProcessedIds = prefs.getStringList('bg_processed_message_ids');
      if (bgProcessedIds != null) {
        _processedMessageIds.addAll(bgProcessedIds);
      }

      final savedHandledDirectives = prefs.getStringList('handled_directive_ids_v1');
      if (savedHandledDirectives != null) {
        _handledDirectiveIds.addAll(savedHandledDirectives);
      }
      // Pre-seed handled directive IDs with all current engine orders and completed history
      for (final o in _engine.activeOrders) {
        if (o.id.isNotEmpty) _handledDirectiveIds.add(o.id);
        if (o.order.id.isNotEmpty) _handledDirectiveIds.add(o.order.id);
        if (o.order.title.trim().isNotEmpty) {
          _handledDirectiveIds.add('title_${o.order.title.trim().toLowerCase()}');
        }
      }
      for (final h in _engine.stats.history) {
        if (h.id.isNotEmpty) _handledDirectiveIds.add(h.id);
        if (h.orderTitle.trim().isNotEmpty) {
          _handledDirectiveIds.add('title_${h.orderTitle.trim().toLowerCase()}');
        }
      }

      final savedPastCodes = prefs.getStringList('past_pairing_codes_v1');
      if (savedPastCodes != null) {
        _pastPairingCodes.addAll(savedPastCodes.map((c) => PartnerService.normalizeCode(c)));
      }
      if (_pairingCode.isNotEmpty) {
        _pastPairingCodes.add(PartnerService.normalizeCode(_pairingCode));
      }

      final rawRemoteActive = prefs.getStringList('director_remote_active_orders_v1');
      if (rawRemoteActive != null) {
        try {
          _remoteActiveOrders = rawRemoteActive
              .map((str) => ActiveOrder.fromJson(jsonDecode(str) as Map<String, dynamic>))
              .toList();
        } catch (_) {}
      }

      final rawRemoteReview = prefs.getStringList('director_remote_review_orders_v1');
      if (rawRemoteReview != null) {
        try {
          _remoteReviewOrders = rawRemoteReview
              .map((str) => ActiveOrder.fromJson(jsonDecode(str) as Map<String, dynamic>))
              .toList();
        } catch (_) {}
      }

      final savedConfirmed = prefs.getStringList('confirmed_player_order_ids_v1');
      if (savedConfirmed != null && savedConfirmed.isNotEmpty) {
        _confirmedOnPlayerOrderIds.addAll(savedConfirmed);
      }

      final savedConfirmedQuests = prefs.getStringList('confirmed_player_quest_ids_v1');
      if (savedConfirmedQuests != null && savedConfirmedQuests.isNotEmpty) {
        _confirmedOnPlayerQuestIds.addAll(savedConfirmedQuests);
      }

      _autoConnect = savedAuto;

      // Drain and apply any directives or messages queued by the background isolate IMMEDIATELY
      // so active directives appear instantaneously on startup without multi-second delay.
      await processPendingBackgroundMessages();

      notifyListeners();

      // Always ensure device is listening to its personal cloud relay inbox topic
      _ensureInboxListener();

      // Start periodic background drain timer while foreground app is active
      _bgDrainTimer?.cancel();
      _bgDrainTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        processPendingBackgroundMessages();
      });

      // Poll missed messages from relay topic(s) that arrived while the app was closed or offline
      pollMissedMessages();

      // Initiate auto-reconnect if enabled
      if (_autoConnect && _pairingCode.isNotEmpty && _pairingSecret.isNotEmpty && _role != ConnectionRole.none) {
        _startReconnectWatchdog();
        _performAutoConnect();
      }
    } catch (e) {
      if (kDebugMode) print('Error initializing SyncService: $e');
    }
  }

  /// Called when app is brought back to the foreground from RAM / background on mobile / desktop
  void onAppResumed() {
    processPendingBackgroundMessages();
    _checkAndAutoReconnect();
    pollMissedMessages();
  }

  /// Ingests orders, chats, reviews, and pairings collected while the app was backgrounded
  Future<void> processPendingBackgroundMessages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      // 1. Queued Directives / Orders
      final rawOrders = prefs.getStringList('pending_background_orders_v1');
      if (rawOrders != null && rawOrders.isNotEmpty) {
        for (final raw in rawOrders) {
          try {
            final data = jsonDecode(raw);
            if (data is! Map) continue;
            final rawOrder = data['order'];
            final Map<String, dynamic> orderData = (rawOrder is Map)
                ? Map<String, dynamic>.from(rawOrder)
                : <String, dynamic>{};
            if (orderData.isEmpty) continue;
            final order = OrderItem.fromJson(orderData);
            if (order.title.startsWith('Surprise Window') && order.description == 'Scheduled directive ready for execution.') {
              continue;
            }
            final senderCode = data['senderCode'] as String? ?? '';
            final senderName = data['senderName'] as String? ?? 'Director';
            final senderId = data['senderId'] as String? ?? '';
            final activeOrderId = data['activeOrderId'] as String?;
            final messageId = data['messageId'] as String?;

            if (messageId != null && messageId.isNotEmpty) {
              _processedMessageIds.add(messageId);
            }

            final isAlreadyHandled = isDirectiveHandled(
              activeOrderId: activeOrderId,
              orderId: order.id,
              msgId: messageId,
              title: order.title,
            );

            final existingOrder = _engine.activeOrders.cast<ActiveOrder?>().firstWhere(
              (o) {
                if (o == null) return false;
                if (activeOrderId != null && activeOrderId.isNotEmpty && o.id == activeOrderId) return true;
                if (order.id.isNotEmpty && (o.id == order.id || o.order.id == order.id)) return true;
                final isMatchingTitle = o.order.title.trim().toLowerCase() == order.title.trim().toLowerCase();
                return isMatchingTitle;
              },
              orElse: () => null,
            );

            final alreadyInHistory = _engine.stats.history.any((h) =>
                (activeOrderId != null && activeOrderId.isNotEmpty && h.id == activeOrderId) ||
                h.orderTitle.trim().toLowerCase() == order.title.trim().toLowerCase());

            final isDirectorAssigned = data['assignedByDirector'] as bool? ?? (senderName != 'Self');
            DateTime? parsedAssignedAt;
            if (data['assignedAt'] is String) {
              parsedAssignedAt = DateTime.tryParse(data['assignedAt'] as String);
            }
            if (existingOrder == null && !isAlreadyHandled && !alreadyInHistory) {
              final assigned = _engine.assignOrder(
                order,
                id: activeOrderId,
                assignedByDirector: isDirectorAssigned,
                assignedByPartnerCode: senderCode,
                assignedByPartnerId: senderId,
                assignedByPartnerName: senderName,
                assignedAt: parsedAssignedAt,
              );
              markDirectiveHandled(
                activeOrderId: assigned.id,
                orderId: order.id,
                msgId: messageId,
                title: order.title,
              );
              _incomingOrderController.add(assigned);
            } else {
              markDirectiveHandled(
                activeOrderId: existingOrder?.id ?? activeOrderId,
                orderId: order.id,
                msgId: messageId,
                title: order.title,
              );
            }
          } catch (e) {
            if (kDebugMode) print('Error processing queued background order: $e');
          }
        }
        await prefs.remove('pending_background_orders_v1');
        broadcastPlayerState();
      }

      // 2. Queued Chat Messages
      final rawChats = prefs.getStringList('pending_background_chats_v1');
      if (rawChats != null && rawChats.isNotEmpty) {
        for (final raw in rawChats) {
          try {
            final data = jsonDecode(raw) as Map<String, dynamic>;
            final text = data['text'] as String? ?? '';
            final senderName = data['senderName'] as String? ?? 'Partner';
            final msgId = data['messageId'] as String? ?? '';
            final senderCode = data['senderCode'] as String? ?? '';
            final senderId = data['senderId'] as String? ?? '';

            PartnerContact? contact = (senderCode.isNotEmpty ? _partnerService?.findContactByCode(senderCode) : null) ??
                _partnerService?.findContactById(senderId);
            if (contact != null && !contact.isBlocked) {
              final incomingMsg = ChatMessage(
                id: msgId.isNotEmpty ? msgId : Uuid().v4(),
                partnerId: contact.id,
                senderId: senderId,
                senderName: senderName,
                text: text,
                timestamp: DateTime.now(),
                isOutgoing: false,
                isRead: false,
              );
              _chatService?.addMessage(incomingMsg);
              _partnerService?.incrementUnread(contact.id);
            }
          } catch (_) {}
        }
        await prefs.remove('pending_background_chats_v1');
      }

      // 3. Queued Reviews (Approvals / Rejections)
      final rawReviews = prefs.getStringList('pending_background_reviews_v1');
      if (rawReviews != null && rawReviews.isNotEmpty) {
        for (final raw in rawReviews) {
          try {
            final data = jsonDecode(raw) as Map<String, dynamic>;
            final approved = data['approved'] as bool? ?? false;
            final tokens = data['rewardTokens'] as int? ?? 0;
            final orderTitle = data['orderTitle'] as String? ?? 'Directive';
            if (approved && tokens > 0) {
              _engine.adjustTokens(tokens, 'Approved directive: $orderTitle');
            }
          } catch (_) {}
        }
        await prefs.remove('pending_background_reviews_v1');
      }

      // 4. Queued Pairing Requests
      final rawPairings = prefs.getStringList('pending_background_pairings_v1');
      if (rawPairings != null && rawPairings.isNotEmpty) {
        for (final raw in rawPairings) {
          try {
            final data = jsonDecode(raw) as Map<String, dynamic>;
            final senderId = data['senderId'] as String? ?? '';
            final senderCode = data['senderCode'] as String? ?? '';
            final senderName = data['senderName'] as String? ?? 'Partner';
            final sharedSecret = data['sharedSecret'] as String? ?? '';
            final cleanSender = PartnerService.normalizeCode(senderCode);
            final isSelf = cleanSender.isNotEmpty &&
                (_pastPairingCodes.contains(cleanSender) ||
                 cleanSender == PartnerService.normalizeCode(_pairingCode) ||
                 (senderId.isNotEmpty && senderId == _deviceId));

            final isHandled = _partnerService?.isRequestHandled(cleanSender, sharedSecret) ?? false;
            final isAlreadyPartner = isSelf ||
                isHandled ||
                (_partnerService?.isExistingContactOrSelf(
                      senderId,
                      senderCode,
                      ownCode: _pairingCode,
                      ownDeviceId: _deviceId,
                    ) ??
                    false);

            if (cleanSender.isNotEmpty && !isAlreadyPartner) {
              _partnerService?.addIncomingRequest(
                IncomingPairingRequest(
                  senderId: senderId,
                  senderCode: senderCode,
                  senderName: senderName,
                  senderRole: PartnerRole.dominant,
                  sharedSecret: sharedSecret,
                  timestamp: DateTime.now(),
                ),
                ownCode: _pairingCode,
                ownDeviceId: _deviceId,
              );
            }
          } catch (_) {}
        }
        await prefs.remove('pending_background_pairings_v1');
      }

      // 5. Queued Quests
      final rawQuests = prefs.getStringList('pending_background_quests_v1');
      if (rawQuests != null && rawQuests.isNotEmpty) {
        for (final raw in rawQuests) {
          try {
            final data = jsonDecode(raw);
            if (data is! Map) continue;
            final rawQuest = data['quest'];
            final Map<String, dynamic> questData = (rawQuest is Map)
                ? Map<String, dynamic>.from(rawQuest)
                : <String, dynamic>{};
            if (questData.isEmpty) continue;
            final quest = Quest.fromJson(questData);
            final senderCode = data['senderCode'] as String? ?? '';
            final senderName = data['senderName'] as String? ?? 'Director';

            _questService?.assignQuestFromDirector(
              quest,
              directorName: senderName,
              directorCode: senderCode,
            );
          } catch (e) {
            if (kDebugMode) print('Error processing queued background quest: $e');
          }
        }
        await prefs.remove('pending_background_quests_v1');
        broadcastPlayerState();
      }
    } catch (e) {
      if (kDebugMode) print('Error processing pending background messages: $e');
    }
  }

  void _saveProcessedMessageIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('processed_sync_message_ids_v2', _processedMessageIds.toList());
      await prefs.setStringList('processed_sync_message_ids', _processedMessageIds.toList());
      await prefs.setStringList('bg_processed_message_ids', _processedMessageIds.toList());
    } catch (_) {}
  }

  void _saveHandledDirectiveIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('handled_directive_ids_v1', _handledDirectiveIds.toList());
    } catch (_) {}
  }

  bool isDirectiveHandled({String? activeOrderId, String? orderId, String? msgId, String? title}) {
    if (activeOrderId != null && activeOrderId.isNotEmpty && _handledDirectiveIds.contains(activeOrderId)) {
      return true;
    }
    if (orderId != null && orderId.isNotEmpty && _handledDirectiveIds.contains(orderId)) {
      return true;
    }
    if (msgId != null && msgId.isNotEmpty && _handledDirectiveIds.contains(msgId)) {
      return true;
    }
    if (title != null && title.trim().isNotEmpty) {
      final cleanTitle = 'title_${title.trim().toLowerCase()}';
      if (_handledDirectiveIds.contains(cleanTitle)) {
        return true;
      }
    }
    return false;
  }

  void markDirectiveHandled({String? activeOrderId, String? orderId, String? msgId, String? title}) {
    bool changed = false;
    if (activeOrderId != null && activeOrderId.isNotEmpty && !_handledDirectiveIds.contains(activeOrderId)) {
      _handledDirectiveIds.add(activeOrderId);
      changed = true;
    }
    if (orderId != null && orderId.isNotEmpty && !_handledDirectiveIds.contains(orderId)) {
      _handledDirectiveIds.add(orderId);
      changed = true;
    }
    if (msgId != null && msgId.isNotEmpty && !_handledDirectiveIds.contains(msgId)) {
      _handledDirectiveIds.add(msgId);
      changed = true;
    }
    if (title != null && title.trim().isNotEmpty) {
      final cleanTitle = 'title_${title.trim().toLowerCase()}';
      if (!_handledDirectiveIds.contains(cleanTitle)) {
        _handledDirectiveIds.add(cleanTitle);
        changed = true;
      }
    }
    if (changed) {
      if (_handledDirectiveIds.length > 500) {
        _handledDirectiveIds.remove(_handledDirectiveIds.first);
      }
      _saveHandledDirectiveIds();
    }
  }

  void _ensureInboxListener() {
    if (_pairingCode.isEmpty) return;
    if (_status == ConnectionStatus.connected && (_cloudSocket != null || _cloudSubscription != null)) {
      return; // Already actively connected and listening
    }
    if (_status == ConnectionStatus.connecting) return;
    connectViaCloudRelay(
      asRole: _role,
      code: _pairingCode,
      password: _pairingSecret,
      isAuto: true,
    );
  }

  void _startReconnectWatchdog() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkAndAutoReconnect();
    });
  }

  void _checkAndAutoReconnect() {
    if (_status == ConnectionStatus.disconnected && _pairingCode.isNotEmpty) {
      _ensureInboxListener();
    }
  }

  Future<void> _performAutoConnect() async {
    if (_status == ConnectionStatus.connecting || _status == ConnectionStatus.connected) return;

    if (_transport == ConnectionTransport.cloudRelay) {
      await connectViaCloudRelay(
        asRole: _role,
        code: _pairingCode,
        password: _pairingSecret,
        isAuto: true,
      );
    } else if (_transport == ConnectionTransport.localWifi && _role == ConnectionRole.player) {
      await startPlayerHost(port: _port, isAuto: true);
    } else if (_transport == ConnectionTransport.directIp && _connectedPeerIp != null && _role == ConnectionRole.director) {
      await connectAsDirector(_connectedPeerIp!, port: _port, isAuto: true);
    }
  }

  Future<void> _savePairingSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pairing_device_id', _deviceId);
      await prefs.setBool('pairing_auto_connect', _autoConnect);
      await prefs.setString('pairing_code', _pairingCode);
      await prefs.setString('pairing_secret', _pairingSecret);
      await prefs.setString('pairing_nickname', _nickname);
      await prefs.setString('pairing_role', _role.name);
      await prefs.setString('pairing_transport', _transport.name);
      await prefs.setString('pairing_custom_relay', _customRelayHost);
      await prefs.setInt('pairing_port', _port);
      if (_connectedPeerIp != null) {
        await prefs.setString('pairing_host_ip', _connectedPeerIp!);
      }
    } catch (_) {}
  }

  ConnectionRole get role => _role;
  ConnectionStatus get status => _status;
  ConnectionTransport get transport => _transport;
  String get statusMessage => _statusMessage;
  bool get autoConnect => _autoConnect;
  String get deviceId => _deviceId;
  String get pairingCode => _pairingCode;
  String get pairingSecret => _pairingSecret;
  String get nickname => _nickname;
  String? get connectedPeerIp => _connectedPeerIp;
  String get customRelayHost => _customRelayHost;
  int get port => _port;

  List<ActiveOrder> get remoteActiveOrders => _remoteActiveOrders;
  List<ActiveOrder> get remoteReviewOrders => _remoteReviewOrders;
  List<ActiveRedemption> get remotePendingRedemptions => _remotePendingRedemptions;
  int get remoteTokens => _remoteTokens;
  int get remoteStreak => _remoteStreak;
  Set<String> get confirmedOnPlayerOrderIds => Set.unmodifiable(_confirmedOnPlayerOrderIds);
  Set<String> get confirmedOnPlayerQuestIds => Set.unmodifiable(_confirmedOnPlayerQuestIds);

  bool isOrderConfirmedOnPlayer(ActiveOrder order) {
    if (_confirmedOnPlayerOrderIds.contains(order.id)) return true;
    if (order.order.id.isNotEmpty && _confirmedOnPlayerOrderIds.contains(order.order.id)) return true;
    if (_confirmedOnPlayerOrderIds.contains(order.order.title.trim().toLowerCase())) return true;
    return false;
  }

  bool isQuestConfirmedOnPlayer(String questId, [String? questTitle]) {
    if (_confirmedOnPlayerQuestIds.contains(questId)) return true;
    if (questTitle != null && questTitle.isNotEmpty && _confirmedOnPlayerQuestIds.contains(questTitle.trim().toLowerCase())) {
      return true;
    }
    return false;
  }

  Future<void> _saveConfirmedOrders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('confirmed_player_order_ids_v1', _confirmedOnPlayerOrderIds.toList());
    } catch (_) {}
  }

  Future<void> _saveConfirmedQuests() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('confirmed_player_quest_ids_v1', _confirmedOnPlayerQuestIds.toList());
    } catch (_) {}
  }

  Future<void> _saveDirectorDispatchedOrders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        'director_remote_active_orders_v1',
        _remoteActiveOrders.map((o) => jsonEncode(o.toJson())).toList(),
      );
      await prefs.setStringList(
        'director_remote_review_orders_v1',
        _remoteReviewOrders.map((o) => jsonEncode(o.toJson())).toList(),
      );
    } catch (_) {}
  }

  void clearRemoteActiveOrder(String activeOrderId, {String? orderId, String? orderTitle}) {
    _remoteActiveOrders.removeWhere((o) =>
        o.id == activeOrderId ||
        (orderId != null && orderId.isNotEmpty && o.order.id == orderId) ||
        (orderTitle != null && orderTitle.isNotEmpty && o.order.title.trim().toLowerCase() == orderTitle.trim().toLowerCase()));

    _confirmedOnPlayerOrderIds.remove(activeOrderId);
    if (orderId != null && orderId.isNotEmpty) _confirmedOnPlayerOrderIds.remove(orderId);
    if (orderTitle != null && orderTitle.isNotEmpty) _confirmedOnPlayerOrderIds.remove(orderTitle.trim().toLowerCase());
    _saveConfirmedOrders();

    // Also remove from local engine active orders
    _engine.removeActiveOrder(activeOrderId);
    if (orderTitle != null && orderTitle.isNotEmpty) {
      final matchingEngine = _engine.activeOrders.where((o) =>
          o.id == activeOrderId ||
          (orderId != null && o.order.id == orderId) ||
          o.order.title.trim().toLowerCase() == orderTitle.trim().toLowerCase()).map((o) => o.id).toList();
      for (final id in matchingEngine) {
        _engine.removeActiveOrder(id);
      }
    }
    _saveDirectorDispatchedOrders();
    notifyListeners();
  }

  void recallDispatchedOrder(String activeOrderId, {String? orderId, String? orderTitle, String? partnerCode}) {
    int idx = _remoteActiveOrders.indexWhere((o) => o.id == activeOrderId);
    if (idx == -1 && orderId != null && orderId.isNotEmpty) {
      idx = _remoteActiveOrders.indexWhere((o) => o.order.id == orderId);
    }
    if (idx == -1 && orderTitle != null && orderTitle.isNotEmpty) {
      idx = _remoteActiveOrders.indexWhere((o) => o.order.title.trim().toLowerCase() == orderTitle.trim().toLowerCase());
    }

    final active = idx != -1 ? _remoteActiveOrders[idx] : null;
    final title = active?.order.title ?? orderTitle ?? 'Directive';
    final targetOrderId = active?.order.id ?? orderId ?? '';
    final code = active?.assignedByPartnerCode ?? partnerCode;
    final partnerId = active?.assignedByPartnerId;

    final myDisplayName = _nickname.isNotEmpty
        ? _nickname
        : (_role == ConnectionRole.director ? 'Director' : 'Dominant');

    final msg = SyncMessage(
      id: const Uuid().v4(),
      type: SyncMessageType.orderStatusUpdate,
      senderId: _deviceId,
      payload: {
        'activeOrderId': activeOrderId,
        'orderId': targetOrderId,
        'orderTitle': title,
        'status': 'recalled',
        'senderCode': _pairingCode,
        'senderId': _deviceId,
        'senderName': myDisplayName,
      },
    );

    // 1. Direct to assigned partner code if available
    if (code != null && code.isNotEmpty) {
      final partner = _partnerService?.findContactByCode(code) ??
          _partnerService?.findContactById(partnerId ?? '');
      sendDirectToTopic(
        code,
        partner?.pairingSecret ?? _pairingSecret,
        msg,
        relayHost: partner != null && partner.customRelayHost.isNotEmpty ? partner.customRelayHost : _customRelayHost,
      );
    }

    // 2. Direct to active partner contact
    final currentActive = _partnerService?.activePartner;
    if (currentActive != null && currentActive.pairingCode.isNotEmpty && currentActive.pairingCode != code) {
      sendDirectToTopic(
        currentActive.pairingCode,
        currentActive.pairingSecret,
        msg,
        relayHost: currentActive.customRelayHost.isNotEmpty ? currentActive.customRelayHost : _customRelayHost,
      );
    }

    // 3. Direct to all submissive contacts
    final submissives = _partnerService?.unblockedContacts.where((c) => c.role == PartnerRole.submissive).toList() ?? [];
    for (final p in submissives) {
      if (p.pairingCode.isNotEmpty && p.pairingCode != code && p.pairingCode != currentActive?.pairingCode) {
        sendDirectToTopic(
          p.pairingCode,
          p.pairingSecret,
          msg,
          relayHost: p.customRelayHost.isNotEmpty ? p.customRelayHost : _customRelayHost,
        );
      }
    }

    // 4. Send to shared personal pairing code
    if (_pairingCode.isNotEmpty) {
      sendDirectToTopic(
        _pairingCode,
        _pairingSecret,
        msg,
        relayHost: _customRelayHost,
      );
    }

    // 5. Send via active socket
    sendMessage(msg);

    // Deep clean locally from both sync and engine
    clearRemoteActiveOrder(activeOrderId, orderId: targetOrderId, orderTitle: title);
  }

  /// Notifies the Director and dominant contacts that the player has emergency-cleared a directive
  Future<void> notifyDirectiveEmergencyCleared(ActiveOrder activeOrder) async {
    // 1. Un-mark from local handled ledger so if Director intentionally re-sends, it can be assigned again
    _handledDirectiveIds.remove(activeOrder.id);
    if (activeOrder.order.id.isNotEmpty) _handledDirectiveIds.remove(activeOrder.order.id);
    _handledDirectiveIds.remove('title_${activeOrder.order.title.trim().toLowerCase()}');
    _saveHandledDirectiveIds();

    final myDisplayName = _nickname.isNotEmpty
        ? _nickname
        : (_role == ConnectionRole.director ? 'Director' : 'Submissive');

    final msg = SyncMessage(
      id: const Uuid().v4(),
      type: SyncMessageType.orderStatusUpdate,
      senderId: _deviceId,
      payload: {
        'activeOrderId': activeOrder.id,
        'orderId': activeOrder.order.id,
        'orderTitle': activeOrder.order.title,
        'status': 'emergencyCleared',
        'reason': 'Emergency Cleared by $myDisplayName',
        'senderCode': _pairingCode,
        'senderId': _deviceId,
        'senderName': myDisplayName,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      },
    );

    // Send direct to assigned partner code
    final code = activeOrder.assignedByPartnerCode;
    final partnerId = activeOrder.assignedByPartnerId;
    if (code != null && code.isNotEmpty) {
      final partner = _partnerService?.findContactByCode(code) ??
          _partnerService?.findContactById(partnerId ?? '');
      sendDirectToTopic(
        code,
        partner?.pairingSecret ?? _pairingSecret,
        msg,
        relayHost: partner != null && partner.customRelayHost.isNotEmpty ? partner.customRelayHost : _customRelayHost,
      );
    }

    // Also send to all unblocked dominant partners
    final dominants = _partnerService?.unblockedContacts.where((c) => c.role == PartnerRole.dominant).toList() ?? [];
    for (final d in dominants) {
      if (d.pairingCode.isNotEmpty && d.pairingCode != code) {
        sendDirectToTopic(
          d.pairingCode,
          d.pairingSecret,
          msg,
          relayHost: d.customRelayHost.isNotEmpty ? d.customRelayHost : _customRelayHost,
        );
      }
    }

    // Send via active socket if connected
    sendMessage(msg);

    // Broadcast updated state
    broadcastPlayerState();
    notifyListeners();
  }

  void clearAllFailedRemoteOrders() {
    for (final o in _remoteActiveOrders.where((o) => o.status == OrderStatus.failed || o.status == OrderStatus.emergencyCleared)) {
      _confirmedOnPlayerOrderIds.remove(o.id);
      if (o.order.id.isNotEmpty) _confirmedOnPlayerOrderIds.remove(o.order.id);
      _confirmedOnPlayerOrderIds.remove(o.order.title.trim().toLowerCase());
    }
    _saveConfirmedOrders();

    _remoteActiveOrders.removeWhere((o) => o.status == OrderStatus.failed || o.status == OrderStatus.emergencyCleared);
    final failedEngineIds = _engine.activeOrders.where((o) => o.status == OrderStatus.failed || o.status == OrderStatus.emergencyCleared).map((o) => o.id).toList();
    for (final id in failedEngineIds) {
      _engine.removeActiveOrder(id);
    }
    _saveDirectorDispatchedOrders();
    notifyListeners();
  }

  void clearAllRemoteOrders() {
    _remoteActiveOrders.clear();
    _confirmedOnPlayerOrderIds.clear();
    _saveConfirmedOrders();

    final allEngineIds = _engine.activeOrders.map((o) => o.id).toList();
    for (final id in allEngineIds) {
      _engine.removeActiveOrder(id);
    }
    _saveDirectorDispatchedOrders();
    notifyListeners();
  }

  void clearRemoteReviewOrder(String activeOrderId, {String? orderId, String? orderTitle}) {
    _remoteReviewOrders.removeWhere((o) =>
        o.id == activeOrderId ||
        (orderId != null && orderId.isNotEmpty && o.order.id == orderId) ||
        (orderTitle != null && orderTitle.isNotEmpty && o.order.title.trim().toLowerCase() == orderTitle.trim().toLowerCase()));
    final matchingUnderReview = _engine.underReviewOrders.where((o) =>
        o.id == activeOrderId ||
        (orderId != null && o.order.id == orderId) ||
        (orderTitle != null && o.order.title.trim().toLowerCase() == orderTitle.trim().toLowerCase())).map((o) => o.id).toList();
    for (final id in matchingUnderReview) {
      _engine.removeActiveOrder(id);
    }
    _saveDirectorDispatchedOrders();
    notifyListeners();
  }

  void clearAllRemoteReviews() {
    _remoteReviewOrders.clear();
    final matchingUnderReview = _engine.underReviewOrders.map((o) => o.id).toList();
    for (final id in matchingUnderReview) {
      _engine.removeActiveOrder(id);
    }
    _saveDirectorDispatchedOrders();
    notifyListeners();
  }

  /// Complete Directive Queue Purge (safe reset for stuck state)
  void purgeAllDirectivesAndReviews() {
    _remoteActiveOrders.clear();
    _remoteReviewOrders.clear();
    final allIds = _engine.activeOrders.map((o) => o.id).toList();
    for (final id in allIds) {
      _engine.removeActiveOrder(id);
    }
    _saveDirectorDispatchedOrders();
    notifyListeners();
  }

  static String generateRandomId(int length) {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rand = Random();
    return List.generate(length, (index) => chars[rand.nextInt(chars.length)]).join();
  }

  static String generateRandomCode([int length = 8]) {
    const chars = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
    final rand = Random.secure();
    final p1 = List.generate(4, (_) => chars[rand.nextInt(chars.length)]).join();
    final p2 = List.generate(4, (_) => chars[rand.nextInt(chars.length)]).join();
    return '$p1-$p2';
  }

  static String generateRandomSecret([int length = 10]) {
    const chars = '23456789abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ';
    final rand = Random.secure();
    return List.generate(length, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  /// Regenerates the user's connection identity (pairing code & secret)
  /// and automatically broadcasts an encrypted migration beacon to all current contacts
  /// so their friend lists update automatically without breaking connectivity.
  Future<void> regeneratePersonalIdentity({bool broadcastMigration = true}) async {
    final newCode = generateRandomCode();
    final newSecret = generateRandomSecret();
    await updatePersonalIdentity(
      newCode: newCode,
      newSecret: newSecret,
      broadcastMigration: broadcastMigration,
    );
  }

  /// Updates personal identity (pairing code and/or secret) and broadcasts migration to contacts
  Future<void> updatePersonalIdentity({
    String? newCode,
    String? newSecret,
    String? newNickname,
    bool broadcastMigration = true,
  }) async {
    final oldCode = _pairingCode;
    final oldSecret = _pairingSecret;
    final cleanNewCode = (newCode != null && newCode.trim().isNotEmpty)
        ? newCode.trim().toUpperCase()
        : _pairingCode;
    final cleanNewSecret = (newSecret != null && newSecret.trim().isNotEmpty)
        ? newSecret.trim()
        : _pairingSecret;

    if (newNickname != null && newNickname.trim().isNotEmpty) {
      _nickname = newNickname.trim();
    }

    if (broadcastMigration && oldCode.isNotEmpty && (cleanNewCode != oldCode || cleanNewSecret != oldSecret)) {
      final migrationMsg = SyncMessage(
        type: SyncMessageType.identityMigrated,
        senderId: _deviceId,
        payload: {
          'deviceId': _deviceId,
          'oldPairingCode': oldCode,
          'newPairingCode': cleanNewCode,
          'oldPairingSecret': oldSecret,
          'newPairingSecret': cleanNewSecret,
          'nickname': _nickname,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        },
      );

      // 1. Dispatch directly to each unblocked friend/contact
      if (_partnerService != null) {
        for (final contact in _partnerService!.unblockedContacts) {
          if (contact.pairingCode.isNotEmpty) {
            try {
              await sendDirectToTopic(
                contact.pairingCode,
                contact.pairingSecret,
                migrationMsg,
                relayHost: contact.customRelayHost,
              );
            } catch (_) {}
          }
        }
      }

      // 2. Publish tombstone redirection beacon to the old personal channel
      try {
        await sendDirectToTopic(
          oldCode,
          oldSecret,
          migrationMsg,
          relayHost: _customRelayHost,
        );
      } catch (_) {}
    }

    // 3. Commit new credentials
    if (oldCode.isNotEmpty) {
      _pastPairingCodes.add(PartnerService.normalizeCode(oldCode));
    }
    _pastPairingCodes.add(PartnerService.normalizeCode(cleanNewCode));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('past_pairing_codes_v1', _pastPairingCodes.toList());
    } catch (_) {}

    _pairingCode = cleanNewCode;
    _pairingSecret = cleanNewSecret;
    await _savePairingSettings();

    // 4. Resubscribe topics
    await resubscribeAllTopics();
    notifyListeners();
  }

  /// Re-evaluates all topic subscriptions and reconnects the WebSocket with updated partner channels
  Future<void> resubscribeAllTopics() async {
    if (_pairingCode.isEmpty) return;
    if (_transport == ConnectionTransport.cloudRelay && _cloudSocket != null) {
      try {
        final topics = <String>{_getHashedTopic(_pairingCode)};
        if (_partnerService != null) {
          for (final c in _partnerService!.contacts) {
            if (c.pairingCode.isNotEmpty) {
              topics.add(_getHashedTopic(c.pairingCode));
            }
          }
        }
        final combinedTopics = topics.join(',');
        final wsUrl = 'wss://$_customRelayHost/$combinedTopics/ws?since=24h';

        await _cloudSubscription?.cancel();
        _cloudSubscription = null;
        try {
          await _cloudSocket?.close();
        } catch (_) {}
        _cloudSocket = null;

        final socket = await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 8));
        _cloudSocket = socket;
        _cloudSubscription = _cloudSocket!.listen(
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
              if (kDebugMode) print('Error parsing incoming relay message: $e');
            }
          },
          onError: (err) {
            if (kDebugMode) print('Cloud relay socket error: $err');
          },
          onDone: () {
            if (_status == ConnectionStatus.connected) {
              _startReconnectWatchdog();
            }
          },
        );
      } catch (e) {
        if (kDebugMode) print('Error resubscribing relay websocket: $e');
      }
    }
    await pollMissedMessages();
  }

  void setNickname(String name) {
    _nickname = name.trim();
    _savePairingSettings();
    notifyListeners();
  }

  void setPairingCode(String code) {
    _pairingCode = code.trim().toUpperCase();
    _savePairingSettings();
    resubscribeAllTopics();
    notifyListeners();
  }

  void setPairingSecret(String secret) {
    _pairingSecret = secret.trim();
    _savePairingSettings();
    notifyListeners();
  }

  void setCustomRelay(String host) {
    _customRelayHost = host.trim().isNotEmpty ? host.trim() : 'ntfy.envs.net';
    _savePairingSettings();
    resubscribeAllTopics();
    notifyListeners();
  }

  static String getHashedTopic(String code) {
    final bytes = utf8.encode('orders_relay_channel_v1_${code.trim().toUpperCase()}');
    final digest = sha256.convert(bytes);
    return 'orders_relay_${digest.toString().substring(0, 24)}';
  }

  String _getHashedTopic(String code) => getHashedTopic(code);

  /// 1. Connect via Global Encrypted Cloud Relay (Zero Configuration / HTTPS / WSS Port 443)
  Future<bool> connectViaCloudRelay({
    required ConnectionRole asRole,
    required String code,
    required String password,
    bool isAuto = false,
  }) async {
    // Always cleanly cancel and tear down any existing subscription/socket
    await _cloudSubscription?.cancel();
    _cloudSubscription = null;
    await _cloudSocket?.close();
    _cloudSocket = null;

    if (!isAuto) await disconnect(explicit: false);

    _role = asRole;
    _transport = ConnectionTransport.cloudRelay;
    if (!isAuto || _pairingCode.isEmpty) {
      if (code.trim().isNotEmpty) _pairingCode = code.trim().toUpperCase();
      if (password.trim().isNotEmpty) _pairingSecret = password.trim();
    }
    _autoConnect = true;
    _status = ConnectionStatus.connecting;
    _statusMessage = 'Connecting to Global Cloud Relay (Port 443)...';
    _savePairingSettings();
    _startReconnectWatchdog();
    notifyListeners();

    try {
      final topics = <String>{_getHashedTopic(_pairingCode)};
      if (_partnerService != null) {
        for (final c in _partnerService!.contacts) {
          if (c.pairingCode.isNotEmpty) {
            topics.add(_getHashedTopic(c.pairingCode));
          }
        }
      }
      final combinedTopics = topics.join(',');
      final wsUrl = 'wss://$_customRelayHost/$combinedTopics/ws?since=24h';

      final socket = await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 8));
      _cloudSocket = socket;
      _status = ConnectionStatus.connected;
      _statusMessage = 'Connected via Global Cloud Link (E2EE)';
      notifyListeners();

      _cloudSubscription = _cloudSocket!.listen(
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
            if (kDebugMode) print('Cloud frame parse error: $e');
          }
        },
        onDone: () {
          _status = ConnectionStatus.disconnected;
          _statusMessage = 'Relay disconnected (Reconnecting...)';
          _cloudSocket = null;
          _cloudSubscription = null;
          notifyListeners();
        },
        onError: (err) {
          _status = ConnectionStatus.disconnected;
          _statusMessage = 'Relay connection error (Reconnecting...)';
          _cloudSocket = null;
          _cloudSubscription = null;
          notifyListeners();
        },
      );

      // Periodic heartbeat & presence refresh
      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(const Duration(seconds: 90), (_) {
        if (_status == ConnectionStatus.connected) {
          if (_role == ConnectionRole.player) {
            broadcastPlayerState();
          } else {
            sendMessage(SyncMessage(type: SyncMessageType.ping, senderId: _deviceId));
          }
        }
      });

      // Poll missed messages from topic history immediately
      pollMissedMessages();

      // Initial state synchronization handshake
      if (_role == ConnectionRole.director) {
        requestStateFromPlayer();
      } else {
        broadcastPlayerState();
      }

      return true;
    } catch (e) {
      if (kDebugMode) print('WebSocket failed ($e), attempting HTTPS SSE fallback...');
      try {
        final topic = _getHashedTopic(_pairingCode);
        final url = Uri.parse('https://$_customRelayHost/$topic/sse?since=24h');
        final req = await _httpClient.getUrl(url).timeout(const Duration(seconds: 8));
        req.headers.set('Accept', 'text/event-stream');
        final res = await req.close();

        if (res.statusCode == 200) {
          _status = ConnectionStatus.connected;
          _statusMessage = 'Connected via Global Cloud Link (SSE/E2EE)';
          notifyListeners();

          _cloudSubscription = res.transform(utf8.decoder).transform(const LineSplitter()).listen(
            (line) async {
              try {
                if (line.startsWith('data:')) {
                  final jsonStr = line.substring(5).trim();
                  if (jsonStr.isNotEmpty) {
                    final parsed = jsonDecode(jsonStr);
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
                      if (raw != null) _processIncomingRaw(raw);
                    }
                  }
                }
              } catch (_) {}
            },
            onDone: () {
              _status = ConnectionStatus.disconnected;
              _statusMessage = 'Relay disconnected (Reconnecting...)';
              _cloudSubscription = null;
              notifyListeners();
            },
            onError: (err) {
              _status = ConnectionStatus.disconnected;
              _statusMessage = 'Relay connection error (Reconnecting...)';
              _cloudSubscription = null;
              notifyListeners();
            },
          );

          // Initial state synchronization handshake
          if (_role == ConnectionRole.director) {
            requestStateFromPlayer();
          } else {
            broadcastPlayerState();
          }

          return true;
        }
      } catch (sseErr) {
        if (kDebugMode) print('SSE fallback also failed: $sseErr');
      }

      _status = ConnectionStatus.disconnected;
      _statusMessage = 'Could not reach relay server. Auto-retrying...';
      _cloudSubscription = null;
      _cloudSocket = null;
      notifyListeners();
      return false;
    }
  }

  /// 2. Start Player (Host) mode on Local Wi-Fi
  Future<bool> startPlayerHost({int port = 8899, bool isAuto = false}) async {
    if (!isAuto) await disconnect(explicit: false);

    _role = ConnectionRole.player;
    _transport = ConnectionTransport.localWifi;
    _port = port;
    _autoConnect = true;
    _status = ConnectionStatus.listening;
    _statusMessage = 'Listening for Director on local network...';
    _savePairingSettings();
    _startReconnectWatchdog();
    notifyListeners();

    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
      _server!.transform(WebSocketTransformer()).listen(_handleIncomingWebSocket);
      return true;
    } catch (e) {
      if (kDebugMode) print('Failed to bind server: $e');
      _status = ConnectionStatus.disconnected;
      _statusMessage = 'Failed to bind local port $port';
      notifyListeners();
      return false;
    }
  }

  void _handleIncomingWebSocket(WebSocket socket) {
    _socket = socket;
    _status = ConnectionStatus.connected;
    _statusMessage = 'Connected via Local Wi-Fi';
    notifyListeners();

    _socketSubscription = _socket!.listen(
      (data) {
        _processIncomingRaw(data.toString());
      },
      onDone: () {
        _status = ConnectionStatus.listening;
        _statusMessage = 'Partner disconnected. Listening...';
        _socket = null;
        notifyListeners();
      },
      onError: (err) {
        _status = ConnectionStatus.listening;
        _socket = null;
        notifyListeners();
      },
    );

    broadcastPlayerState();
  }

  /// 3. Connect as Director to Player IP / Direct IP
  Future<bool> connectAsDirector(String hostIp, {int port = 8899, bool isAuto = false}) async {
    if (!isAuto) await disconnect(explicit: false);

    _role = ConnectionRole.director;
    _transport = ConnectionTransport.directIp;
    _connectedPeerIp = hostIp;
    _port = port;
    _autoConnect = true;
    _status = ConnectionStatus.connecting;
    _statusMessage = 'Connecting to $hostIp:$port...';
    _savePairingSettings();
    _startReconnectWatchdog();
    notifyListeners();

    try {
      final wsUrl = 'ws://$hostIp:$port';
      final socket = await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 5));
      _socket = socket;
      _status = ConnectionStatus.connected;
      _statusMessage = 'Connected to $hostIp';
      notifyListeners();

      _socketSubscription = _socket!.listen(
        (data) {
          _processIncomingRaw(data.toString());
        },
        onDone: () {
          _status = ConnectionStatus.disconnected;
          _statusMessage = 'Host disconnected (Reconnecting...)';
          _socket = null;
          notifyListeners();
        },
        onError: (err) {
          _status = ConnectionStatus.disconnected;
          _statusMessage = 'Connection error (Reconnecting...)';
          _socket = null;
          notifyListeners();
        },
      );

      requestStateFromPlayer();
      return true;
    } catch (e) {
      if (kDebugMode) print('Director connection error: $e');
      _status = ConnectionStatus.disconnected;
      _statusMessage = 'Could not connect to $hostIp:$port';
      notifyListeners();
      return false;
    }
  }

  void attachChatService(ChatService chatService) {
    _chatService = chatService;
  }

  void attachServices(PartnerService partnerService, ChatService chatService, {QuestService? questService}) {
    _partnerService = partnerService;
    _chatService = chatService;
    if (questService != null) {
      _questService = questService;
    }

    // Self-healing: if personal pairing code was corrupted by a past bug to match a partner contact's code,
    // regenerate a clean personal pairing code and re-establish the inbox listener.
    for (final contact in _partnerService!.contacts) {
      if (contact.pairingCode.isNotEmpty &&
          contact.pairingCode.toUpperCase() == _pairingCode.toUpperCase()) {
        _pairingCode = generateRandomCode(6);
        _savePairingSettings();
        _ensureInboxListener();
        break;
      }
    }
  }

  void attachQuestService(QuestService questService) {
    _questService = questService;
  }

  Future<bool> switchActivePartner(PartnerContact partner) async {
    await _partnerService?.setActivePartner(partner.id);
    if (partner.customRelayHost.isNotEmpty) {
      _customRelayHost = partner.customRelayHost;
      _savePairingSettings();
    }
    notifyListeners();
    return true;
  }

  Future<bool> sendPairingRequest({
    required String targetCode,
    String? targetName,
    required PartnerRole targetRole,
  }) async {
    final cleanCode = targetCode.trim().toUpperCase();
    final sharedSecret = generateRandomSecret(12);

    final myRole = _role == ConnectionRole.director ? PartnerRole.dominant : PartnerRole.submissive;
    final contactName = targetName != null && targetName.trim().isNotEmpty
        ? targetName.trim()
        : 'Partner ($cleanCode)';

    // Save as pending contact locally
    final newContact = PartnerContact(
      displayName: contactName,
      pairingCode: cleanCode,
      pairingSecret: sharedSecret,
      role: targetRole,
    );
    await _partnerService?.addContact(newContact);

    final myDisplayName = _nickname.isNotEmpty
        ? _nickname
        : (_role == ConnectionRole.director ? 'Director' : 'Submissive');

    final msg = SyncMessage(
      type: SyncMessageType.pairingRequest,
      senderId: _deviceId,
      payload: {
        'senderId': _deviceId,
        'senderCode': _pairingCode,
        'senderName': myDisplayName,
        'senderRole': myRole.name,
        'targetRole': targetRole.name,
        'sharedSecret': sharedSecret,
      },
    );

    return await sendDirectToTopic(cleanCode, '', msg);
  }

  Future<bool> acceptPairingRequest(IncomingPairingRequest req, {String? customName}) async {
    await _partnerService?.markRequestHandled(req.senderCode, req.sharedSecret);
    final contact = PartnerContact(
      id: req.senderId,
      displayName: customName != null && customName.trim().isNotEmpty
          ? customName.trim()
          : (req.senderName.isNotEmpty ? req.senderName : 'Partner (${req.senderCode})'),
      pairingCode: req.senderCode,
      pairingSecret: req.sharedSecret,
      role: req.senderRole,
    );

    await _partnerService?.addContact(contact);
    _partnerService?.removeIncomingRequest(req.senderId);
    _partnerService?.removeIncomingRequest(req.senderCode);

    final myDisplayName = _nickname.isNotEmpty
        ? _nickname
        : (_role == ConnectionRole.director ? 'Director' : 'Submissive');

    final msg = SyncMessage(
      type: SyncMessageType.pairingAccept,
      senderId: _deviceId,
      payload: {
        'senderId': _deviceId,
        'senderCode': _pairingCode,
        'senderName': myDisplayName,
        'sharedSecret': req.sharedSecret,
      },
    );

    return await sendDirectToTopic(req.senderCode, '', msg);
  }

  Future<bool> declinePairingRequest(IncomingPairingRequest req) async {
    await _partnerService?.markRequestHandled(req.senderCode, req.sharedSecret);
    _partnerService?.removeIncomingRequest(req.senderId);
    _partnerService?.removeIncomingRequest(req.senderCode);
    final msg = SyncMessage(
      type: SyncMessageType.pairingDecline,
      senderId: _deviceId,
      payload: {
        'senderId': _deviceId,
        'senderCode': _pairingCode,
      },
    );
    return await sendDirectToTopic(req.senderCode, '', msg);
  }

  Future<bool> sendChatMessage(
    PartnerContact partner,
    String text, {
    String? imageBase64,
    String? packType,
    String? packData,
    String? packTitle,
    int? packItemCount,
    bool isEncryptedPack = false,
  }) async {
    final msgId = const Uuid().v4();
    final myDisplayName = _nickname.isNotEmpty
        ? _nickname
        : (_role == ConnectionRole.director ? 'Director' : 'Submissive');

    final localMsg = ChatMessage(
      id: msgId,
      partnerId: partner.id,
      senderId: _deviceId,
      senderName: myDisplayName,
      text: text,
      imageBase64: imageBase64,
      timestamp: DateTime.now(),
      isOutgoing: true,
      isRead: true,
      packType: packType,
      packData: packData,
      packTitle: packTitle,
      packItemCount: packItemCount,
      isEncryptedPack: isEncryptedPack,
    );

    await _chatService?.addMessage(localMsg);
    _processedMessageIds.add(msgId);
    _saveProcessedMessageIds();

    final syncMsg = SyncMessage(
      id: msgId,
      type: SyncMessageType.chatMessage,
      senderId: _deviceId,
      targetId: partner.id,
      timestamp: localMsg.timestamp,
      payload: {
        'messageId': msgId,
        'senderId': _deviceId,
        'senderCode': _pairingCode,
        'senderName': myDisplayName,
        'text': text,
        'imageBase64': imageBase64,
        'packType': packType,
        'packData': packData,
        'packTitle': packTitle,
        'packItemCount': packItemCount,
        'isEncryptedPack': isEncryptedPack,
      },
    );

    // Send direct to partner's topic with encryption
    return await sendDirectToTopic(
      partner.pairingCode,
      partner.pairingSecret,
      syncMsg,
      relayHost: partner.customRelayHost.isNotEmpty ? partner.customRelayHost : _customRelayHost,
    );
  }

  Future<bool> sendEditChatMessage(PartnerContact partner, String messageId, String newText) async {
    final editedTime = DateTime.now();
    await _chatService?.editMessage(partner.id, messageId, newText, editedTime: editedTime);

    final syncMsg = SyncMessage(
      type: SyncMessageType.chatEditMessage,
      senderId: _deviceId,
      targetId: partner.id,
      timestamp: editedTime,
      payload: {
        'messageId': messageId,
        'partnerId': _deviceId,
        'senderCode': _pairingCode,
        'newText': newText,
        'editedTimestamp': editedTime.toIso8601String(),
      },
    );

    return await sendDirectToTopic(
      partner.pairingCode,
      partner.pairingSecret,
      syncMsg,
      relayHost: partner.customRelayHost.isNotEmpty ? partner.customRelayHost : _customRelayHost,
    );
  }

  Future<bool> sendDeleteChatMessage(PartnerContact partner, String messageId) async {
    await _chatService?.deleteMessage(partner.id, messageId);

    final syncMsg = SyncMessage(
      type: SyncMessageType.chatDeleteMessage,
      senderId: _deviceId,
      targetId: partner.id,
      payload: {
        'messageId': messageId,
        'partnerId': _deviceId,
        'senderCode': _pairingCode,
      },
    );

    return await sendDirectToTopic(
      partner.pairingCode,
      partner.pairingSecret,
      syncMsg,
      relayHost: partner.customRelayHost.isNotEmpty ? partner.customRelayHost : _customRelayHost,
    );
  }

  /// Fetches historical messages from the relay topic(s) that arrived while app was closed or offline
  Future<void> pollMissedMessages() async {
    if (_pairingCode.isEmpty) return;

    final topics = <String>{_getHashedTopic(_pairingCode)};
    if (_partnerService != null) {
      for (final c in _partnerService!.contacts) {
        if (c.pairingCode.isNotEmpty) {
          topics.add(_getHashedTopic(c.pairingCode));
        }
      }
    }

    final host = _customRelayHost.isNotEmpty ? _customRelayHost : 'ntfy.envs.net';

    for (final topic in topics) {
      try {
        final url = Uri.parse('https://$host/$topic/json?poll=1&since=24h');
        final req = await _httpClient.getUrl(url).timeout(const Duration(seconds: 6));
        final res = await req.close().timeout(const Duration(seconds: 6));
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
      } catch (e) {
        if (kDebugMode) print('Error polling missed messages on $host for topic $topic: $e');
      }
    }
  }

  Future<bool> sendDirectToTopic(
    String code,
    String secret,
    SyncMessage msg, {
    String? relayHost,
  }) async {
    final primaryHost = (relayHost != null && relayHost.isNotEmpty) ? relayHost : _customRelayHost;
    final hostsToTry = <String>[primaryHost];
    // Only try alternative host if primary host fails
    final fallbackHost = primaryHost == 'ntfy.envs.net' ? 'ntfy.sh' : 'ntfy.envs.net';
    hostsToTry.add(fallbackHost);

    final jsonStr = msg.encode();
    final payload = secret.isNotEmpty ? EncryptionHelper.encryptString(jsonStr, secret) : jsonStr;
    final topic = _getHashedTopic(code);

    String titleHeader = 'OrdersApp Alert';
    String priorityHeader = '4';
    String tagsHeader = 'bell';

    switch (msg.type) {
      case SyncMessageType.dispatchOrder:
        final orderData = msg.payload['order'] as Map<String, dynamic>?;
        final orderTitle = orderData?['title'] as String? ?? 'New Directive';
        final senderName = msg.payload['senderName'] as String? ?? 'Director';
        titleHeader = 'Directive from $senderName: $orderTitle';
        priorityHeader = '5';
        tagsHeader = 'warning,bell';
        break;
      case SyncMessageType.approveProof:
        final orderTitle = msg.payload['orderTitle'] as String? ?? 'Your directive';
        final senderName = msg.payload['senderName'] as String? ?? 'Director';
        final tokens = msg.payload['rewardTokens'] as int? ?? 0;
        titleHeader = 'Approved by $senderName: "$orderTitle" (+${tokens} tokens)';
        priorityHeader = '4';
        tagsHeader = 'white_check_mark';
        break;
      case SyncMessageType.rejectProof:
        final orderTitle = msg.payload['orderTitle'] as String? ?? 'Your directive';
        final senderName = msg.payload['senderName'] as String? ?? 'Director';
        titleHeader = 'Revision requested by $senderName: "$orderTitle"';
        priorityHeader = '4';
        tagsHeader = 'x';
        break;
      case SyncMessageType.chatMessage:
        final senderName = msg.payload['senderName'] as String? ?? 'Partner';
        titleHeader = 'Message from $senderName';
        priorityHeader = '4';
        tagsHeader = 'speech_balloon';
        break;
      case SyncMessageType.pairingRequest:
        final senderName = msg.payload['senderName'] as String? ?? 'Partner';
        titleHeader = 'Pairing request from $senderName';
        priorityHeader = '4';
        tagsHeader = 'link';
        break;
      case SyncMessageType.dispatchQuest:
        final rawQuest = msg.payload['quest'];
        final questTitle = (rawQuest is Map ? rawQuest['title'] : null) as String? ?? 'New Quest';
        final senderName = msg.payload['senderName'] as String? ?? 'Director';
        titleHeader = 'Quest from $senderName: $questTitle';
        priorityHeader = '5';
        tagsHeader = 'sparkles,bell';
        break;
      case SyncMessageType.questStepCompleted:
        final questTitle = msg.payload['questTitle'] as String? ?? 'Quest';
        final senderName = msg.payload['senderName'] as String? ?? 'Player';
        final stepIndex = (msg.payload['stepIndex'] as num?)?.toInt() ?? 0;
        final stepTitle = msg.payload['stepTitle'] as String? ?? 'Step';
        titleHeader = '$senderName completed step ${stepIndex + 1}: $stepTitle';
        priorityHeader = '4';
        tagsHeader = 'white_check_mark';
        break;
      case SyncMessageType.questCompleted:
        final questTitle = msg.payload['questTitle'] as String? ?? 'Quest';
        final senderName = msg.payload['senderName'] as String? ?? 'Player';
        final bonusTokens = (msg.payload['bonusTokens'] as num?)?.toInt() ?? 0;
        titleHeader = '🏆 $senderName Conquered Quest: $questTitle (+$bonusTokens tokens)';
        priorityHeader = '5';
        tagsHeader = 'trophy,star2';
        break;
      default:
        titleHeader = 'OrdersApp Sync Update';
        priorityHeader = '3';
        tagsHeader = 'bell';
        break;
    }

    final safeTitle = titleHeader.replaceAll(RegExp(r'[^\x20-\x7E]'), '').trim();

    for (final host in hostsToTry) {
      try {
        final url = Uri.parse('https://$host/$topic');
        final req = await _httpClient.postUrl(url).timeout(const Duration(seconds: 6));
        req.headers.set('X-Title', safeTitle.isNotEmpty ? safeTitle : 'OrdersApp');
        req.headers.set('X-Priority', priorityHeader);
        req.headers.set('X-Tags', tagsHeader);

        if (payload.length > 3500) {
          req.headers.set('X-Filename', 'payload.bin');
          req.headers.contentType = ContentType.binary;
          req.add(utf8.encode(payload));
        } else {
          req.headers.contentType = ContentType.text;
          req.write(payload);
        }

        final res = await req.close().timeout(const Duration(seconds: 6));
        await res.drain();
        if (res.statusCode == 200) {
          return true;
        } else if (res.statusCode == 429) {
          if (kDebugMode) print('Relay $host rate-limited (429), failing over to next relay...');
          continue;
        }
      } catch (e) {
        if (kDebugMode) print('Failed sending to $host: $e, trying next relay...');
      }
    }
    return false;
  }

  bool _isOwnMessage(SyncMessage? msg) {
    if (msg == null) return false;
    if (_deviceId.isNotEmpty && msg.senderId == _deviceId) return true;
    if (_deviceId.isNotEmpty && msg.payload['senderId'] == _deviceId) return true;
    final senderCode = msg.payload['senderCode'] as String?;
    if (senderCode != null && senderCode.isNotEmpty) {
      final clean = PartnerService.normalizeCode(senderCode);
      if (clean.isNotEmpty) {
        if (_pastPairingCodes.contains(clean) || clean == PartnerService.normalizeCode(_pairingCode)) {
          return true;
        }
      }
    }
    return false;
  }

  Future<void> _processIncomingRaw(String raw) async {
    SyncMessage? message;

    // 1. Try direct plain JSON (e.g. unencrypted pairingRequest, pairingAccept)
    try {
      final msg = SyncMessage.decode(raw);
      if (!_isOwnMessage(msg)) {
        message = msg;
      }
    } catch (_) {}

    // 2. Try decrypting with local personal _pairingSecret
    if (message == null && _pairingSecret.isNotEmpty) {
      try {
        final plainJson = EncryptionHelper.decryptString(raw, _pairingSecret);
        final msg = SyncMessage.decode(plainJson);
        if (!_isOwnMessage(msg)) {
          message = msg;
        }
      } catch (_) {}
    }

    // 3. Try decrypting with each saved partner's pairingSecret
    if (message == null && _partnerService != null) {
      for (final partner in _partnerService!.contacts) {
        if (partner.pairingSecret.isNotEmpty && partner.pairingSecret != _pairingSecret) {
          try {
            final plainJson = EncryptionHelper.decryptString(raw, partner.pairingSecret);
            final msg = SyncMessage.decode(plainJson);
            if (!_isOwnMessage(msg)) {
              message = msg;
              break;
            }
          } catch (_) {}
        }
      }
    }

    if (message != null && !_isOwnMessage(message)) {
      try {
        await _handleSyncMessage(message);
      } catch (e) {
        if (kDebugMode) print('Error handling sync message: $e');
      }
    }
  }

  @visibleForTesting
  Future<void> handleIncomingSyncMessage(SyncMessage msg) async {
    await _handleSyncMessage(msg);
  }

  Future<void> _handleSyncMessage(SyncMessage msg) async {
    if (_isOwnMessage(msg)) return;

    if (msg.id.isNotEmpty) {
      if (_processedMessageIds.contains(msg.id)) return;
      _processedMessageIds.add(msg.id);
      if (_processedMessageIds.length > 500) {
        _processedMessageIds.remove(_processedMessageIds.first);
      }
      _saveProcessedMessageIds();
    }

    // 1. Check if sender is blocked
    if (_partnerService?.isSenderBlocked(msg.senderId) == true) return;
    final payloadSenderCode = msg.payload['senderCode'] as String?;
    if (payloadSenderCode != null && payloadSenderCode.isNotEmpty) {
      if (_partnerService?.isSenderBlocked(payloadSenderCode) == true) return;
    }

    switch (msg.type) {
      case SyncMessageType.pairingRequest:
        final senderId = msg.payload['senderId'] as String? ?? msg.senderId;
        final senderCode = msg.payload['senderCode'] as String? ?? '';
        final senderName = msg.payload['senderName'] as String? ?? 'Partner';
        final senderRoleStr = msg.payload['senderRole'] as String? ?? 'submissive';
        final sharedSecret = msg.payload['sharedSecret'] as String? ?? '';

        final senderRole = PartnerRole.values.firstWhere(
          (e) => e.name == senderRoleStr,
          orElse: () => PartnerRole.submissive,
        );

        final cleanSender = PartnerService.normalizeCode(senderCode);

        // 1. Ignore if sender is self (current identity, past identity, or device ID)
        if (cleanSender.isNotEmpty &&
            (_pastPairingCodes.contains(cleanSender) ||
             cleanSender == PartnerService.normalizeCode(_pairingCode) ||
             (senderId.isNotEmpty && senderId == _deviceId))) {
          return;
        }

        // 2. Check if sender is ALREADY in contacts / friend list
        final existingContact = _partnerService?.findContactByCode(cleanSender) ??
            _partnerService?.findContactById(senderId);

        if (existingContact != null) {
          // If the partner is already on the contact list, mark handled, update secret or lastSeen seamlessly without re-prompting
          _partnerService?.markRequestHandled(cleanSender, sharedSecret);
          if (sharedSecret.isNotEmpty && existingContact.pairingSecret != sharedSecret) {
            _partnerService?.updateContact(existingContact.copyWith(
              pairingSecret: sharedSecret,
              lastSeen: DateTime.now(),
            ));
          } else {
            _partnerService?.updateLastSeen(existingContact.id);
          }
          return;
        }

        // 3. Ignore if already handled / accepted / declined
        if (_partnerService?.isRequestHandled(cleanSender, sharedSecret) == true) {
          return;
        }

        if (senderCode.isNotEmpty && sharedSecret.isNotEmpty) {
          _partnerService?.addIncomingRequest(
            IncomingPairingRequest(
              senderId: senderId,
              senderCode: senderCode,
              senderName: senderName,
              senderRole: senderRole,
              sharedSecret: sharedSecret,
              timestamp: msg.timestamp,
            ),
            ownCode: _pairingCode,
            ownDeviceId: _deviceId,
          );
          NotificationService.showPairingRequestNotification(
            senderName: senderName,
            senderCode: senderCode,
          );
          SoundService.playAlarm();
        }
        break;

      case SyncMessageType.pairingAccept:
        final senderId = msg.payload['senderId'] as String? ?? msg.senderId;
        final senderCode = msg.payload['senderCode'] as String? ?? '';
        final senderName = msg.payload['senderName'] as String? ?? 'Partner';
        final sharedSecret = msg.payload['sharedSecret'] as String? ?? '';

        final existing = _partnerService?.findContactByCode(senderCode) ??
            _partnerService?.findContactById(senderId);
        if (existing != null) {
          _partnerService?.updateContact(existing.copyWith(
            displayName: senderName.isNotEmpty ? senderName : existing.displayName,
            pairingSecret: sharedSecret.isNotEmpty ? sharedSecret : existing.pairingSecret,
          ));
        }
        break;

      case SyncMessageType.pairingDecline:
        final senderCode = msg.payload['senderCode'] as String? ?? '';
        if (senderCode.isNotEmpty) {
          _partnerService?.removeIncomingRequest(senderCode);
        }
        break;

      case SyncMessageType.identityMigrated:
        final senderDeviceId = msg.payload['deviceId'] as String? ?? msg.senderId;
        final oldCode = msg.payload['oldPairingCode'] as String? ?? '';
        final newCode = msg.payload['newPairingCode'] as String? ?? '';
        final newSecret = msg.payload['newPairingSecret'] as String? ?? '';
        final senderName = msg.payload['nickname'] as String? ?? msg.payload['senderName'] as String? ?? '';

        if (newCode.isNotEmpty && _partnerService != null) {
          final updated = await _partnerService!.updateContactPairingIdentity(
            deviceId: senderDeviceId,
            oldCode: oldCode,
            newCode: newCode,
            newSecret: newSecret,
            newDisplayName: senderName,
          );

          if (updated) {
            await resubscribeAllTopics();
            notifyListeners();
            NotificationService.showGenericNotification(
              title: 'Partner Connection Updated',
              body: '${senderName.isNotEmpty ? senderName : "Partner"} refreshed their connection code. Link updated automatically.',
            );

            // Send back acknowledgement to the new channel
            try {
              final ackMsg = SyncMessage(
                type: SyncMessageType.identityMigratedAck,
                senderId: _deviceId,
                payload: {
                  'status': 'migrated_ack',
                  'partnerId': _deviceId,
                  'senderCode': _pairingCode,
                  'recipientCode': newCode,
                },
              );
              await sendDirectToTopic(
                newCode,
                newSecret.isNotEmpty ? newSecret : _pairingSecret,
                ackMsg,
              );
            } catch (_) {}
          }
        }
        break;

      case SyncMessageType.identityMigratedAck:
        if (kDebugMode) print('Partner acknowledged identity migration: ${msg.senderId}');
        break;

      case SyncMessageType.chatMessage:
        final text = msg.payload['text'] as String? ?? '';
        final image = msg.payload['imageBase64'] as String?;
        final senderName = msg.payload['senderName'] as String? ?? 'Partner';
        final msgId = msg.payload['messageId'] as String? ?? msg.id;
        final senderCode = msg.payload['senderCode'] as String? ?? '';
        final packType = msg.payload['packType'] as String?;
        final packData = msg.payload['packData'] as String?;
        final packTitle = msg.payload['packTitle'] as String?;
        final packItemCount = (msg.payload['packItemCount'] as num?)?.toInt();
        final isEncryptedPack = msg.payload['isEncryptedPack'] as bool? ?? false;

        PartnerContact? contact = (senderCode.isNotEmpty ? _partnerService?.findContactByCode(senderCode) : null) ??
            _partnerService?.findContactById(msg.senderId);

        if (contact == null) return; // Do NOT auto-add unknown senders as contacts!
        final partnerId = contact.id;
        if (contact.isBlocked) return;

        final incomingMsg = ChatMessage(
          id: msgId,
          partnerId: partnerId,
          senderId: msg.senderId,
          senderName: senderName,
          text: text,
          imageBase64: image,
          timestamp: msg.timestamp,
          isOutgoing: false,
          isRead: _chatService?.activeChatPartnerId == partnerId,
          packType: packType,
          packData: packData,
          packTitle: packTitle,
          packItemCount: packItemCount,
          isEncryptedPack: isEncryptedPack,
        );

        _chatService?.addMessage(incomingMsg);
        if (_chatService?.activeChatPartnerId == partnerId) {
          _partnerService?.resetUnread(partnerId);
        } else {
          _partnerService?.incrementUnread(partnerId);
        }
        break;

      case SyncMessageType.chatEditMessage:
        final msgId = msg.payload['messageId'] as String? ?? '';
        final newText = msg.payload['newText'] as String? ?? '';
        final editedStr = msg.payload['editedTimestamp'] as String?;
        final editedTime = editedStr != null ? DateTime.tryParse(editedStr) : msg.timestamp;
        final senderCode = msg.payload['senderCode'] as String? ?? '';

        PartnerContact? contact = (senderCode.isNotEmpty ? _partnerService?.findContactByCode(senderCode) : null) ??
            _partnerService?.findContactById(msg.senderId);
        final partnerId = contact?.id ?? msg.senderId;

        if (msgId.isNotEmpty) {
          _chatService?.editMessage(partnerId, msgId, newText, editedTime: editedTime);
        }
        break;

      case SyncMessageType.chatDeleteMessage:
        final msgId = msg.payload['messageId'] as String? ?? '';
        final senderCode = msg.payload['senderCode'] as String? ?? '';

        PartnerContact? contact = (senderCode.isNotEmpty ? _partnerService?.findContactByCode(senderCode) : null) ??
            _partnerService?.findContactById(msg.senderId);
        final partnerId = contact?.id ?? msg.senderId;

        if (msgId.isNotEmpty) {
          _chatService?.deleteMessage(partnerId, msgId);
        }
        break;

      case SyncMessageType.chatReadReceipt:
        final partnerId = msg.payload['partnerId'] as String? ?? msg.senderId;
        _chatService?.markAsRead(partnerId);
        break;

      case SyncMessageType.dispatchOrder:
        try {
          final rawOrder = msg.payload['order'];
          final Map<String, dynamic> orderData = (rawOrder is Map)
              ? Map<String, dynamic>.from(rawOrder)
              : <String, dynamic>{};
          if (orderData.isEmpty) break;
          final order = OrderItem.fromJson(orderData);
          final senderCode = msg.payload['senderCode'] as String? ?? msg.senderId;
          final senderName = msg.payload['senderName'] as String? ?? 'Director';
          final senderId = msg.senderId;
          final activeOrderId = msg.payload['activeOrderId'] as String?;
          final isResend = msg.payload['isResend'] == true || msg.payload['forceAssign'] == true;

          String assignedId = activeOrderId ?? order.id;

          // 1. Check if this directive has already been handled (active, completed, reviewed, or dismissed)
          final isAlreadyHandled = isDirectiveHandled(
            activeOrderId: activeOrderId,
            orderId: order.id,
            msgId: msg.id,
            title: order.title,
          );

          // 2. Check if this directive already exists on this device in any state
          final existingOrder = _engine.activeOrders.cast<ActiveOrder?>().firstWhere(
            (o) {
              if (o == null) return false;
              if (activeOrderId != null && activeOrderId.isNotEmpty && o.id == activeOrderId) return true;
              if (order.id.isNotEmpty && (o.id == order.id || o.order.id == order.id)) return true;
              final isMatchingTitle = o.order.title.trim().toLowerCase() == order.title.trim().toLowerCase();
              return isMatchingTitle;
            },
            orElse: () => null,
          );

          // 3. Check if this directive is currently actively running or under review
          final isAlreadyActive = existingOrder != null &&
              (existingOrder.status == OrderStatus.active ||
               existingOrder.status == OrderStatus.pending ||
               existingOrder.status == OrderStatus.underReview);

          // 4. Check if already recorded in completed discipline history
          final alreadyInHistory = _engine.stats.history.any((h) =>
              (activeOrderId != null && activeOrderId.isNotEmpty && h.id == activeOrderId) ||
              h.orderTitle.trim().toLowerCase() == order.title.trim().toLowerCase());

          // If Director explicitly re-sent and it's not currently running, unblock it!
          final shouldMount = (!isAlreadyActive && isResend) ||
              (existingOrder == null && !isAlreadyHandled && !alreadyInHistory);

          if (shouldMount) {
            // Remove previous suppression if this is a deliberate re-send
            if (isResend) {
              if (activeOrderId != null) _handledDirectiveIds.remove(activeOrderId);
              if (order.id.isNotEmpty) _handledDirectiveIds.remove(order.id);
              _handledDirectiveIds.remove('title_${order.title.trim().toLowerCase()}');
            }

            DateTime? parsedAssignedAt;
            if (msg.payload['assignedAt'] is String) {
              parsedAssignedAt = DateTime.tryParse(msg.payload['assignedAt'] as String);
            }

            final assigned = _engine.assignOrder(
              order,
              id: activeOrderId,
              assignedByDirector: true,
              assignedByPartnerCode: senderCode,
              assignedByPartnerId: senderId,
              assignedByPartnerName: senderName,
              assignedAt: parsedAssignedAt,
            );
            assignedId = assigned.id;
            markDirectiveHandled(
              activeOrderId: assigned.id,
              orderId: order.id,
              msgId: msg.id,
              title: order.title,
            );
            _incomingOrderController.add(assigned);
            try {
              NotificationService.showOrderDispatchedNotification(
                title: order.title,
                description: order.description,
                assignerName: senderName,
                rewardTokens: order.rewardTokens,
              );
            } catch (_) {}
            try {
              SoundService.playAlarm();
            } catch (_) {}
          } else {
            // Already handled, active, or completed — retain status and suppress re-notification
            assignedId = existingOrder?.id ?? activeOrderId ?? order.id;
            markDirectiveHandled(
              activeOrderId: assignedId,
              orderId: order.id,
              msgId: msg.id,
              title: order.title,
            );
          }

          // Acknowledge receipt to Director immediately
          if (senderCode.isNotEmpty) {
            final ackMsg = SyncMessage(
              type: SyncMessageType.dispatchOrderAck,
              senderId: _deviceId,
              payload: {
                'activeOrderId': assignedId,
                'orderId': order.id,
                'orderTitle': order.title,
                'senderCode': _pairingCode,
                'senderName': _nickname.isNotEmpty ? _nickname : 'Submissive',
              },
            );
            final contact = _partnerService?.findContactByCode(senderCode) ??
                _partnerService?.findContactById(senderId);
            sendDirectToTopic(
              senderCode,
              contact?.pairingSecret ?? _pairingSecret,
              ackMsg,
              relayHost: contact != null && contact.customRelayHost.isNotEmpty ? contact.customRelayHost : _customRelayHost,
            );
          }

          // Force immediate state broadcast
          _doBroadcastNow();
        } catch (e) {
          if (kDebugMode) print('Error processing dispatchOrder: $e');
        }
        break;

      case SyncMessageType.dispatchOrderAck:
        try {
          final activeOrderId = msg.payload['activeOrderId'] as String?;
          final orderId = msg.payload['orderId'] as String?;
          final orderTitle = msg.payload['orderTitle'] as String?;

          if (activeOrderId != null && activeOrderId.isNotEmpty) {
            _confirmedOnPlayerOrderIds.add(activeOrderId);
          }
          if (orderId != null && orderId.isNotEmpty) {
            _confirmedOnPlayerOrderIds.add(orderId);
          }
          if (orderTitle != null && orderTitle.isNotEmpty) {
            _confirmedOnPlayerOrderIds.add(orderTitle.trim().toLowerCase());
          }
          _saveConfirmedOrders();
          notifyListeners();
        } catch (e) {
          if (kDebugMode) print('Error processing dispatchOrderAck: $e');
        }
        break;

      case SyncMessageType.orderStatusUpdate:
        try {
          final activeOrderId = msg.payload['activeOrderId'] as String?;
          final statusStr = msg.payload['status'] as String?;
          final orderTitle = msg.payload['orderTitle'] as String? ?? 'Directive';
          final orderId = msg.payload['orderId'] as String? ?? '';
          final reason = msg.payload['reason'] as String?;
          final senderName = msg.payload['senderName'] as String? ?? 'Player';

          if (statusStr == 'failed') {
            final idx = _remoteActiveOrders.indexWhere(
              (o) => (activeOrderId != null && o.id == activeOrderId) ||
                     (orderId.isNotEmpty && o.order.id == orderId) ||
                     o.order.title.toLowerCase() == orderTitle.toLowerCase(),
            );
            if (idx != -1) {
              _remoteActiveOrders[idx] = _remoteActiveOrders[idx].copyWith(
                status: OrderStatus.failed,
                directorNote: reason ?? 'Failed / Forfeited by Player',
                completedAt: DateTime.now(),
              );
              _saveDirectorDispatchedOrders();
            }
            NotificationService.showOrderFailedNotification(
              title: orderTitle,
              playerName: senderName,
              reason: reason,
            );
            try {
              SoundService.playAlarm();
            } catch (_) {}
            notifyListeners();
          } else if (statusStr == 'recalled') {
            // Find all matching active orders on player side
            final matchingIds = _engine.activeOrders.where((o) {
              if (activeOrderId != null && o.id == activeOrderId) return true;
              if (orderId.isNotEmpty && o.order.id == orderId) return true;
              if (orderTitle.isNotEmpty && o.order.title.trim().toLowerCase() == orderTitle.trim().toLowerCase()) return true;
              return false;
            }).map((o) => o.id).toList();

            for (final id in matchingIds) {
              _engine.removeActiveOrder(id);
            }

            // Also check underReviewOrders if player had already submitted proof
            final matchingReviewIds = _engine.underReviewOrders.where((o) {
              if (activeOrderId != null && o.id == activeOrderId) return true;
              if (orderId.isNotEmpty && o.order.id == orderId) return true;
              if (orderTitle.isNotEmpty && o.order.title.trim().toLowerCase() == orderTitle.trim().toLowerCase()) return true;
              return false;
            }).map((o) => o.id).toList();

            for (final id in matchingReviewIds) {
              _engine.removeActiveOrder(id);
            }

            try {
              NotificationService.showProofReviewedNotification(
                title: orderTitle.isNotEmpty ? orderTitle : 'Directive',
                approved: false,
                reviewerName: '$senderName (Directive Recalled)',
              );
            } catch (_) {}

            broadcastPlayerState();
            notifyListeners();
          } else if (statusStr == 'emergencyCleared' || statusStr == 'cleared') {
            final idx = _remoteActiveOrders.indexWhere(
              (o) => (activeOrderId != null && activeOrderId.isNotEmpty && o.id == activeOrderId) ||
                     (orderId.isNotEmpty && o.order.id == orderId) ||
                     o.order.title.toLowerCase() == orderTitle.toLowerCase(),
            );
            if (idx != -1) {
              _remoteActiveOrders[idx] = _remoteActiveOrders[idx].copyWith(
                status: OrderStatus.emergencyCleared,
                directorNote: reason ?? 'Emergency Cleared by ${senderName.isNotEmpty ? senderName : "Submissive"}',
              );
              _saveDirectorDispatchedOrders();
            }
            if (activeOrderId != null && activeOrderId.isNotEmpty) {
              _confirmedOnPlayerOrderIds.remove(activeOrderId);
            }
            if (orderId.isNotEmpty) {
              _confirmedOnPlayerOrderIds.remove(orderId);
            }
            _confirmedOnPlayerOrderIds.remove(orderTitle.toLowerCase());
            _saveConfirmedOrders();

            NotificationService.showGenericNotification(
              title: 'Directive Emergency Cleared',
              body: '${senderName.isNotEmpty ? senderName : "Submissive"} emergency-cleared "$orderTitle".',
            );
            try {
              SoundService.playAlertSound();
            } catch (_) {}
            notifyListeners();
          } else if (statusStr == 'completed') {
            _remoteActiveOrders.removeWhere(
              (o) => (activeOrderId != null && o.id == activeOrderId) ||
                     (orderId.isNotEmpty && o.order.id == orderId) ||
                     o.order.title.toLowerCase() == orderTitle.toLowerCase(),
            );
            _saveDirectorDispatchedOrders();
            notifyListeners();
          }
        } catch (e) {
          if (kDebugMode) print('Error processing orderStatusUpdate: $e');
        }
        break;

      case SyncMessageType.submitProof:
        try {
          if (msg.payload['activeOrder'] != null) {
            final order = ActiveOrder.fromJson(msg.payload['activeOrder'] as Map<String, dynamic>);
            _remoteActiveOrders.removeWhere((o) =>
                o.id == order.id ||
                (o.order.id.isNotEmpty && o.order.id == order.order.id) ||
                o.order.title.trim().toLowerCase() == order.order.title.trim().toLowerCase());
            _remoteReviewOrders.removeWhere((o) =>
                o.id == order.id ||
                (o.order.id.isNotEmpty && o.order.id == order.order.id) ||
                o.order.title.trim().toLowerCase() == order.order.title.trim().toLowerCase());
            _remoteReviewOrders.insert(0, order);
            _saveDirectorDispatchedOrders();

            // Track who sent the proof so we can route approval/rejection back
            final proofSenderCode = msg.payload['senderCode'] as String?;
            final proofSenderId = msg.payload['senderId'] as String?;
            if (proofSenderCode != null && proofSenderCode.isNotEmpty) {
              _remoteReviewSenderCode[order.id] = proofSenderCode;
            }
            if (proofSenderId != null && proofSenderId.isNotEmpty) {
              _remoteReviewSenderId[order.id] = proofSenderId;
            }

            final senderName = _partnerService?.findContactByCode(proofSenderCode ?? '')?.displayName ??
                _partnerService?.findContactById(proofSenderId ?? '')?.displayName;

            final hasActionTimer = order.order.durationType == DurationType.actionTimer ||
                order.order.durationType == DurationType.actionWithDeadline;
            final isIncompleteTimer = hasActionTimer && !order.isActionTimerFinished && order.actionSecondsRemaining > 0;

            NotificationService.showProofSubmittedNotification(
              title: order.order.title,
              senderName: senderName,
              isIncompleteTimer: isIncompleteTimer,
              secondsRemaining: isIncompleteTimer ? order.actionSecondsRemaining : null,
            );
            SoundService.playAlarm();

            notifyListeners();
          }
        } catch (_) {}
        requestStateFromPlayer();
        break;

      case SyncMessageType.approveProof:
        final activeOrderId = msg.payload['activeOrderId'] as String;
        final note = msg.payload['directorNote'] as String?;
        _engine.approveProof(activeOrderId, directorNote: note);
        try {
          final approvedOrder = _engine.completedOrders.firstWhere(
            (o) => o.id == activeOrderId,
            orElse: () => _engine.activeOrders.firstWhere((o) => o.id == activeOrderId),
          );
          NotificationService.showProofReviewedNotification(
            title: approvedOrder.order.title,
            approved: true,
            reviewerName: approvedOrder.assignedByPartnerName,
            tokensAwarded: approvedOrder.order.rewardTokens,
          );
          SoundService.playAlarm();
        } catch (_) {}
        broadcastPlayerState();
        break;

      case SyncMessageType.rejectProof:
        final activeOrderId = msg.payload['activeOrderId'] as String;
        final reason = msg.payload['reason'] as String? ?? 'Rejected by Director';
        final returnToQueue = msg.payload['returnToQueue'] == true;

        if (returnToQueue) {
          _engine.returnProofToQueue(activeOrderId, reason: reason);
          try {
            final returnedOrder = _engine.activeOrders.firstWhere((o) => o.id == activeOrderId);
            NotificationService.showProofReviewedNotification(
              title: returnedOrder.order.title,
              approved: false,
              reviewerName: '${returnedOrder.assignedByPartnerName ?? "Director"} (Returned to Queue - Try Again)',
            );
            SoundService.playAlarm();
          } catch (_) {}
        } else {
          _engine.rejectProof(activeOrderId, reason: reason, penalize: true);
          try {
            final rejectedOrder = _engine.activeOrders.firstWhere((o) => o.id == activeOrderId);
            NotificationService.showProofReviewedNotification(
              title: rejectedOrder.order.title,
              approved: false,
              reviewerName: '${rejectedOrder.assignedByPartnerName ?? "Director"} (Penalized -${rejectedOrder.order.penaltyTokens} Tokens)',
            );
            SoundService.playAlarm();
          } catch (_) {}
        }
        broadcastPlayerState();
        break;

      case SyncMessageType.adjustTokens:
        final delta = (msg.payload['delta'] as num?)?.toInt() ?? 0;
        final reason = msg.payload['reason'] as String? ?? 'Director Adjustment';
        _engine.adjustTokens(delta, reason);
        broadcastPlayerState();
        break;

      case SyncMessageType.syncPacks:
        final packData = msg.payload['pack'] as Map<String, dynamic>;
        final pack = OrderPack.fromJson(packData);
        _engine.addPack(pack);
        broadcastPlayerState();
        break;

      case SyncMessageType.requestState:
        broadcastPlayerState();
        break;

      case SyncMessageType.sendState:
        try {
          _remoteTokens = (msg.payload['tokens'] as num?)?.toInt() ?? 0;
          _remoteStreak = (msg.payload['streak'] as num?)?.toInt() ?? 0;

          if (msg.payload['underReviewOrders'] is List) {
            _remoteReviewOrders = (msg.payload['underReviewOrders'] as List)
                .map((e) => ActiveOrder.fromJson(e as Map<String, dynamic>))
                .toList();

            // Remove any orders that are now under review from active list
            for (final rev in _remoteReviewOrders) {
              _remoteActiveOrders.removeWhere(
                (o) => o.id == rev.id ||
                       (o.order.id.isNotEmpty && o.order.id == rev.order.id) ||
                       o.order.title.trim().toLowerCase() == rev.order.title.trim().toLowerCase(),
              );
            }
          }

          if (msg.payload['activeOrders'] is List) {
            final incomingActive = (msg.payload['activeOrders'] as List)
                .map((e) => ActiveOrder.fromJson(e as Map<String, dynamic>))
                .where((e) =>
                    e.status != OrderStatus.underReview &&
                    !_remoteReviewOrders.any((r) =>
                        r.id == e.id ||
                        (r.order.id.isNotEmpty && r.order.id == e.order.id) ||
                        r.order.title.trim().toLowerCase() == e.order.title.trim().toLowerCase()))
                .toList();

            final Map<String, ActiveOrder> merged = {};
            for (final local in _remoteActiveOrders) {
              if (local.status != OrderStatus.underReview &&
                  !_remoteReviewOrders.any((r) =>
                      r.id == local.id ||
                      (r.order.id.isNotEmpty && r.order.id == local.order.id) ||
                      r.order.title.trim().toLowerCase() == local.order.title.trim().toLowerCase())) {
                final isPresentOnPlayer = incomingActive.any((inO) =>
                    inO.id == local.id ||
                    (inO.order.id.isNotEmpty && inO.order.id == local.order.id) ||
                    inO.order.title.trim().toLowerCase() == local.order.title.trim().toLowerCase());

                if (!isPresentOnPlayer &&
                    isOrderConfirmedOnPlayer(local) &&
                    local.status != OrderStatus.failed &&
                    local.status != OrderStatus.cancelled &&
                    local.status != OrderStatus.emergencyCleared) {
                  // Submissive cleared this directive from their dashboard!
                  final updatedLocal = local.copyWith(
                    status: OrderStatus.emergencyCleared,
                    directorNote: 'Emergency Cleared by Submissive',
                  );
                  merged[local.id] = updatedLocal;
                  _confirmedOnPlayerOrderIds.remove(local.id);
                  if (local.order.id.isNotEmpty) _confirmedOnPlayerOrderIds.remove(local.order.id);
                  _confirmedOnPlayerOrderIds.remove(local.order.title.trim().toLowerCase());
                } else {
                  merged[local.id] = local;
                }
              }
            }
            for (final incoming in incomingActive) {
              merged[incoming.id] = incoming;
              _confirmedOnPlayerOrderIds.add(incoming.id);
              if (incoming.order.id.isNotEmpty) _confirmedOnPlayerOrderIds.add(incoming.order.id);
              _confirmedOnPlayerOrderIds.add(incoming.order.title.trim().toLowerCase());
            }
            _remoteActiveOrders = merged.values.toList();
            _saveConfirmedOrders();
          }

          if (msg.payload['underReviewOrders'] is List) {
            for (final rev in _remoteReviewOrders) {
              _confirmedOnPlayerOrderIds.add(rev.id);
              if (rev.order.id.isNotEmpty) _confirmedOnPlayerOrderIds.add(rev.order.id);
              _confirmedOnPlayerOrderIds.add(rev.order.title.trim().toLowerCase());
            }
            _saveConfirmedOrders();
          }

          if (msg.payload['pendingRedemptions'] is List) {
            _remotePendingRedemptions = (msg.payload['pendingRedemptions'] as List)
                .map((e) => ActiveRedemption.fromJson(e as Map<String, dynamic>))
                .toList();
          }

          if (msg.payload['activeQuest'] is Map) {
            try {
              final activeQuestMap = Map<String, dynamic>.from(msg.payload['activeQuest'] as Map);
              final activeQuest = ActiveQuest.fromJson(activeQuestMap);
              _questService?.updateRemotePlayerQuestFromState(msg.senderId, activeQuest);
            } catch (e) {
              if (kDebugMode) print('Error parsing activeQuest from remote state: $e');
            }
          }

          _saveDirectorDispatchedOrders();
          notifyListeners();
        } catch (e) {
          if (kDebugMode) print('Error parsing remote state: $e');
        }
        break;

      case SyncMessageType.ping:
        if (_role == ConnectionRole.player) {
          broadcastPlayerState();
        } else {
          sendMessage(SyncMessage(type: SyncMessageType.pong, senderId: _deviceId));
        }
        break;

      case SyncMessageType.dispatchQuest:
        try {
          final rawQuest = msg.payload['quest'];
          final Map<String, dynamic> questData = (rawQuest is Map)
              ? Map<String, dynamic>.from(rawQuest)
              : <String, dynamic>{};
          final quest = Quest.fromJson(questData);
          final senderName = msg.payload['senderName'] as String? ?? 'Director';
          final senderCode = msg.payload['senderCode'] as String? ?? '';

          _questService?.assignQuestFromDirector(
            quest,
            directorName: senderName,
            directorCode: senderCode,
          );

          // Acknowledge receipt to Director immediately
          if (senderCode.isNotEmpty) {
            final ackMsg = SyncMessage(
              type: SyncMessageType.dispatchQuestAck,
              senderId: _deviceId,
              payload: {
                'questId': quest.id,
                'questTitle': quest.title,
                'senderCode': _pairingCode,
                'senderName': _nickname.isNotEmpty ? _nickname : 'Submissive',
              },
            );
            final contact = _partnerService?.findContactByCode(senderCode) ??
                _partnerService?.findContactById(msg.senderId);
            sendDirectToTopic(
              senderCode,
              contact?.pairingSecret ?? _pairingSecret,
              ackMsg,
              relayHost: contact?.customRelayHost.isNotEmpty == true ? contact!.customRelayHost : _customRelayHost,
            );
          }

          try {
            NotificationService.showOrderDispatchedNotification(
              title: 'Quest: ${quest.title}',
              description: '${quest.steps.length} chained directives assigned by $senderName. (${quest.totalPotentialTokens} total tokens)',
              assignerName: senderName,
              rewardTokens: quest.bonusTokensOnComplete,
            );
          } catch (_) {}
          try {
            SoundService.playAlarm();
          } catch (_) {}
          broadcastPlayerState();
        } catch (e) {
          if (kDebugMode) print('Error handling dispatchQuest: $e');
        }
        break;

      case SyncMessageType.dispatchQuestAck:
        try {
          final questId = msg.payload['questId'] as String? ?? '';
          if (questId.isNotEmpty) {
            _confirmedOnPlayerQuestIds.add(questId);
          }
          final questTitle = msg.payload['questTitle'] as String?;
          if (questTitle != null && questTitle.isNotEmpty) {
            _confirmedOnPlayerQuestIds.add(questTitle.trim().toLowerCase());
          }
          _saveConfirmedQuests();
          notifyListeners();
        } catch (e) {
          if (kDebugMode) print('Error processing dispatchQuestAck: $e');
        }
        break;

      case SyncMessageType.questStepCompleted:
        try {
          final senderName = msg.payload['senderName'] as String? ?? 'Player';
          final questTitle = msg.payload['questTitle'] as String? ?? 'Quest';
          final stepIndex = (msg.payload['stepIndex'] as num?)?.toInt() ?? 0;
          final stepTitle = msg.payload['stepTitle'] as String? ?? 'Step';
          final totalSteps = (msg.payload['totalSteps'] as num?)?.toInt() ?? 1;

          _questService?.updateRemotePlayerQuestProgress(
            senderId: msg.senderId,
            questId: msg.payload['questId'] as String? ?? '',
            questTitle: questTitle,
            stepIndex: stepIndex,
            stepTitle: stepTitle,
            totalSteps: totalSteps,
          );

          NotificationService.showProofReviewedNotification(
            title: '$questTitle (Step ${stepIndex + 1}/$totalSteps: $stepTitle)',
            approved: true,
            reviewerName: senderName,
            tokensAwarded: (msg.payload['tokensAwarded'] as num?)?.toInt(),
          );
        } catch (_) {}
        break;

      case SyncMessageType.questCompleted:
        try {
          final senderName = msg.payload['senderName'] as String? ?? 'Player';
          final questTitle = msg.payload['questTitle'] as String? ?? 'Quest';
          final bonusTokens = (msg.payload['bonusTokens'] as num?)?.toInt() ?? 0;

          _questService?.markRemotePlayerQuestCompleted(
            msg.senderId,
            msg.payload['questId'] as String? ?? '',
          );

          NotificationService.showProofReviewedNotification(
            title: 'CONQUERED: $questTitle',
            approved: true,
            reviewerName: senderName,
            tokensAwarded: bonusTokens,
          );
          SoundService.playAlarm();
        } catch (_) {}
        break;

      case SyncMessageType.pong:
        break;
      default:
        break;
    }
  }

  /// Sends a specific completed proof to director for immediate review
  void sendProofForReview(ActiveOrder activeOrder) {
    final msg = SyncMessage(
      id: Uuid().v4(),
      type: SyncMessageType.submitProof,
      senderId: _deviceId,
      payload: {
        'activeOrder': activeOrder.toJson(),
        'senderCode': _pairingCode,
        'senderId': _deviceId,
      },
    );

    // 1. If assigned by a specific director partner, send directly to that partner
    PartnerContact? partner;
    if (activeOrder.assignedByPartnerId != null && activeOrder.assignedByPartnerId!.isNotEmpty) {
      partner = _partnerService?.findContactById(activeOrder.assignedByPartnerId!);
    }
    if (partner == null && activeOrder.assignedByPartnerCode != null && activeOrder.assignedByPartnerCode!.isNotEmpty) {
      partner = _partnerService?.findContactByCode(activeOrder.assignedByPartnerCode!);
    }

    if (partner != null) {
      sendDirectToTopic(
        partner.pairingCode,
        partner.pairingSecret,
        msg,
        relayHost: partner.customRelayHost.isNotEmpty ? partner.customRelayHost : _customRelayHost,
      );
      return;
    }

    if (activeOrder.assignedByPartnerCode != null && activeOrder.assignedByPartnerCode!.isNotEmpty) {
      sendDirectToTopic(
        activeOrder.assignedByPartnerCode!,
        _pairingSecret,
        msg,
      );
      return;
    }

    // 2. If self-assigned or partner not found, send to active partner or primary dominant contact
    final active = _partnerService?.activePartner;
    if (active != null) {
      sendDirectToTopic(
        active.pairingCode,
        active.pairingSecret,
        msg,
        relayHost: active.customRelayHost.isNotEmpty ? active.customRelayHost : _customRelayHost,
      );
      return;
    }

    final dominants = _partnerService?.unblockedContacts.where((c) => c.role == PartnerRole.dominant).toList() ?? [];
    if (dominants.isNotEmpty) {
      for (final d in dominants) {
        sendDirectToTopic(
          d.pairingCode,
          d.pairingSecret,
          msg,
          relayHost: d.customRelayHost.isNotEmpty ? d.customRelayHost : _customRelayHost,
        );
      }
      return;
    }

    sendMessage(msg);
  }

  /// Throttled broadcast: enforces minimum interval between state broadcasts
  /// to avoid flooding relay servers and hitting rate limits.
  void broadcastPlayerState() {
    final now = DateTime.now();
    if (_lastBroadcastTime != null &&
        now.difference(_lastBroadcastTime!) < _broadcastMinInterval) {
      // Too soon — schedule a deferred broadcast if one isn't already pending
      _broadcastDebounceTimer?.cancel();
      _broadcastDebounceTimer = Timer(_broadcastMinInterval, () {
        _doBroadcastNow();
      });
      return;
    }
    _doBroadcastNow();
  }

  /// Immediate broadcast: sends state now without throttle checks.
  /// Used by explicit user actions (proof submit, dispatch response, etc.)
  void _doBroadcastNow() {
    _lastBroadcastTime = DateTime.now();
    _broadcastDebounceTimer?.cancel();

    final msg = SyncMessage(
      id: Uuid().v4(),
      type: SyncMessageType.sendState,
      senderId: _deviceId,
      payload: {
        'tokens': _engine.stats.tokens,
        'streak': _engine.stats.currentStreakDays,
        'score': _engine.stats.disciplineScore,
        'activeOrders': _engine.currentRunningOrders.map((o) => o.toJson()).toList(),
        'underReviewOrders': _engine.underReviewOrders.map((o) => o.toJson()).toList(),
        'pendingRedemptions': _engine.pendingRedemptions.map((r) => r.toJson()).toList(),
        if (_questService?.activeQuest != null)
          'activeQuest': _questService!.activeQuest!.toJson(),
      },
    );

    // 1. Send via active transport if connected
    sendMessage(msg);

    // 2. Also send direct to all unblocked dominant partners
    final dominants = _partnerService?.unblockedContacts
        .where((c) => c.role == PartnerRole.dominant)
        .toList() ?? [];
    if (dominants.isNotEmpty) {
      for (final partner in dominants) {
        sendDirectToTopic(
          partner.pairingCode,
          partner.pairingSecret,
          msg,
          relayHost: partner.customRelayHost.isNotEmpty ? partner.customRelayHost : _customRelayHost,
        );
      }
    } else {
      final active = _partnerService?.activePartner;
      if (active != null) {
        sendDirectToTopic(
          active.pairingCode,
          active.pairingSecret,
          msg,
          relayHost: active.customRelayHost.isNotEmpty ? active.customRelayHost : _customRelayHost,
        );
      }
    }
  }

  void requestStateFromPlayer({PartnerContact? targetPartner}) {
    final msg = SyncMessage(
      id: Uuid().v4(),
      type: SyncMessageType.requestState,
      senderId: _deviceId,
    );

    if (targetPartner != null) {
      sendDirectToTopic(
        targetPartner.pairingCode,
        targetPartner.pairingSecret,
        msg,
        relayHost: targetPartner.customRelayHost.isNotEmpty ? targetPartner.customRelayHost : _customRelayHost,
      );
      return;
    }

    final submissives = _partnerService?.unblockedContacts
        .where((c) => c.role == PartnerRole.submissive)
        .toList() ?? [];
    if (submissives.isNotEmpty) {
      for (final partner in submissives) {
        sendDirectToTopic(
          partner.pairingCode,
          partner.pairingSecret,
          msg,
          relayHost: partner.customRelayHost.isNotEmpty ? partner.customRelayHost : _customRelayHost,
        );
      }
      return;
    }

    final active = _partnerService?.activePartner;
    if (active != null) {
      sendDirectToTopic(
        active.pairingCode,
        active.pairingSecret,
        msg,
        relayHost: active.customRelayHost.isNotEmpty ? active.customRelayHost : _customRelayHost,
      );
    }
  }

  /// Asynchronous message dispatcher that prevents socket starvation
  Future<bool> sendMessageAsync(SyncMessage msg) async {
    try {
      final jsonStr = msg.encode();
      final payload = _pairingSecret.isNotEmpty
          ? EncryptionHelper.encryptString(jsonStr, _pairingSecret)
          : jsonStr;

      if (_transport == ConnectionTransport.cloudRelay) {
        if (_pairingCode.isEmpty) return false;
        final topic = _getHashedTopic(_pairingCode);
        final url = Uri.parse('https://$_customRelayHost/$topic');
        final req = await _httpClient.postUrl(url).timeout(const Duration(seconds: 8));

        if (payload.length > 3500) {
          req.headers.set('X-Filename', 'payload.bin');
          req.headers.contentType = ContentType.binary;
          req.headers.set('X-Title', 'OrdersApp');
          req.add(utf8.encode(payload));
        } else {
          req.headers.contentType = ContentType.text;
          req.headers.set('X-Title', 'OrdersApp');
          req.write(payload);
        }

        final res = await req.close().timeout(const Duration(seconds: 8));
        await res.drain();
        return res.statusCode == 200;
      } else if (_socket != null && _status == ConnectionStatus.connected) {
        _socket!.add(payload);
        return true;
      }
      return false;
    } catch (e) {
      if (kDebugMode) print('Failed to send sync message: $e');
      return false;
    }
  }

  /// Sends a command to connected peer (via HTTPS POST relay or direct WebSocket)
  bool sendMessage(SyncMessage msg) {
    sendMessageAsync(msg);
    return true;
  }

  /// Director command helpers with targeted routing
  bool dispatchOrderToPlayer(
    OrderItem order, {
    PartnerContact? targetPartner,
    DateTime? assignedAt,
  }) {
    final myDisplayName = _nickname.isNotEmpty
        ? _nickname
        : (_role == ConnectionRole.director ? 'Director' : 'Dominant');

    final assignedId = const Uuid().v4();

    // 0. Direct to Self (This Device)
    if (targetPartner != null && targetPartner.isSelf) {
      final assigned = _engine.assignOrder(
        order,
        id: assignedId,
        assignedByDirector: true,
        assignedByPartnerCode: _pairingCode,
        assignedByPartnerId: PartnerContact.selfId,
        assignedByPartnerName: myDisplayName.isNotEmpty ? '$myDisplayName (Self)' : 'Self (Director)',
        assignedAt: assignedAt,
      );
      _remoteActiveOrders.removeWhere(
        (o) => o.id == assigned.id || (o.order.title == order.title && o.assignedByPartnerId == PartnerContact.selfId),
      );
      _remoteActiveOrders.insert(0, assigned);
      _confirmedOnPlayerOrderIds.add(assignedId);
      if (order.id.isNotEmpty) _confirmedOnPlayerOrderIds.add(order.id);
      _confirmedOnPlayerOrderIds.add(order.title.trim().toLowerCase());
      _saveConfirmedOrders();
      _saveDirectorDispatchedOrders();
      try {
        NotificationService.showOrderDispatchedNotification(
          title: order.title,
          description: order.description,
          assignerName: myDisplayName.isNotEmpty ? '$myDisplayName (Self)' : 'Self (Director)',
          rewardTokens: order.rewardTokens,
        );
      } catch (_) {}
      try {
        SoundService.playAlarm();
      } catch (_) {}
      notifyListeners();
      return true;
    }

    final msg = SyncMessage(
      id: const Uuid().v4(),
      type: SyncMessageType.dispatchOrder,
      senderId: _deviceId,
      payload: {
        'order': order.toJson(),
        'activeOrderId': assignedId,
        'senderCode': _pairingCode,
        'senderId': _deviceId,
        'senderName': myDisplayName,
        if (assignedAt != null) 'assignedAt': assignedAt.toIso8601String(),
      },
    );

    bool dispatched = false;

    // 1. Direct to selected partner contact
    if (targetPartner != null && targetPartner.pairingCode.isNotEmpty) {
      sendDirectToTopic(
        targetPartner.pairingCode,
        targetPartner.pairingSecret,
        msg,
        relayHost: targetPartner.customRelayHost.isNotEmpty ? targetPartner.customRelayHost : _customRelayHost,
      );
      dispatched = true;
    }

    // 2. Direct to active partner contact
    final active = _partnerService?.activePartner;
    if (active != null && active.id != targetPartner?.id && active.pairingCode.isNotEmpty) {
      sendDirectToTopic(
        active.pairingCode,
        active.pairingSecret,
        msg,
        relayHost: active.customRelayHost.isNotEmpty ? active.customRelayHost : _customRelayHost,
      );
      dispatched = true;
    }

    // 3. Direct to all submissive contacts
    final submissives = _partnerService?.unblockedContacts.where((c) => c.role == PartnerRole.submissive).toList() ?? [];
    for (final p in submissives) {
      if (p.id != targetPartner?.id && p.id != active?.id && p.pairingCode.isNotEmpty) {
        sendDirectToTopic(
          p.pairingCode,
          p.pairingSecret,
          msg,
          relayHost: p.customRelayHost.isNotEmpty ? p.customRelayHost : _customRelayHost,
        );
        dispatched = true;
      }
    }

    // 4. Send to shared personal pairing code (PairingView pairing channel)
    if (_pairingCode.isNotEmpty) {
      sendDirectToTopic(
        _pairingCode,
        _pairingSecret,
        msg,
        relayHost: _customRelayHost,
      );
      dispatched = true;
    }

    // 5. Send via active local socket if available
    sendMessage(msg);

    // Retain dispatched order copy on Director side
    final assigned = ActiveOrder(
      id: assignedId,
      order: order,
      status: OrderStatus.active,
      assignedByDirector: true,
      assignedByPartnerCode: targetPartner?.pairingCode ?? _partnerService?.activePartner?.pairingCode ?? _pairingCode,
      assignedByPartnerName: targetPartner?.displayName ?? _partnerService?.activePartner?.displayName ?? 'Submissive',
      assignedByPartnerId: targetPartner?.id ?? _partnerService?.activePartnerId,
    );

    _remoteActiveOrders.removeWhere(
      (o) => o.id == assigned.id ||
             (o.order.title == order.title && o.assignedByPartnerCode == assigned.assignedByPartnerCode),
    );
    _remoteActiveOrders.insert(0, assigned);
    _saveDirectorDispatchedOrders();
    notifyListeners();

    return dispatched;
  }

  /// Re-sends a specific active directive to ensure delivery and triggers submissive dashboard sync
  Future<bool> resendDispatchedOrder(ActiveOrder activeOrder, {PartnerContact? targetPartner}) async {
    final myDisplayName = _nickname.isNotEmpty
        ? _nickname
        : (_role == ConnectionRole.director ? 'Director' : 'Dominant');

    // 0. Reset directive status back to active on Director side if previously emergencyCleared or cancelled
    final idx = _remoteActiveOrders.indexWhere((o) =>
        o.id == activeOrder.id ||
        (o.order.id.isNotEmpty && o.order.id == activeOrder.order.id) ||
        o.order.title.trim().toLowerCase() == activeOrder.order.title.trim().toLowerCase());
    if (idx != -1) {
      _remoteActiveOrders[idx] = _remoteActiveOrders[idx].copyWith(
        status: OrderStatus.active,
        clearDirectorNote: true,
      );
      _saveDirectorDispatchedOrders();
    }
    _confirmedOnPlayerOrderIds.remove(activeOrder.id);
    if (activeOrder.order.id.isNotEmpty) _confirmedOnPlayerOrderIds.remove(activeOrder.order.id);
    _confirmedOnPlayerOrderIds.remove(activeOrder.order.title.trim().toLowerCase());
    _saveConfirmedOrders();

    final msg = SyncMessage(
      id: const Uuid().v4(),
      type: SyncMessageType.dispatchOrder,
      senderId: _deviceId,
      payload: {
        'order': activeOrder.order.toJson(),
        'activeOrderId': activeOrder.id,
        'senderCode': _pairingCode,
        'senderId': _deviceId,
        'senderName': myDisplayName,
        'isResend': true,
        'forceAssign': true,
      },
    );

    bool dispatched = false;

    // 1. Direct to explicit partner or assigned contact
    PartnerContact? partner = targetPartner;
    if (partner == null && activeOrder.assignedByPartnerId != null && activeOrder.assignedByPartnerId!.isNotEmpty) {
      partner = _partnerService?.findContactById(activeOrder.assignedByPartnerId!);
    }
    if (partner == null && activeOrder.assignedByPartnerCode != null && activeOrder.assignedByPartnerCode!.isNotEmpty) {
      partner = _partnerService?.findContactByCode(activeOrder.assignedByPartnerCode!);
    }
    partner ??= _partnerService?.activePartner;

    if (partner != null && partner.pairingCode.isNotEmpty) {
      await sendDirectToTopic(
        partner.pairingCode,
        partner.pairingSecret,
        msg,
        relayHost: partner.customRelayHost.isNotEmpty ? partner.customRelayHost : _customRelayHost,
      );
      dispatched = true;
    }

    // 2. Direct to all other submissive contacts
    final submissives = _partnerService?.unblockedContacts.where((c) => c.role == PartnerRole.submissive).toList() ?? [];
    for (final p in submissives) {
      if (p.id != partner?.id && p.pairingCode.isNotEmpty) {
        await sendDirectToTopic(
          p.pairingCode,
          p.pairingSecret,
          msg,
          relayHost: p.customRelayHost.isNotEmpty ? p.customRelayHost : _customRelayHost,
        );
        dispatched = true;
      }
    }

    // 3. Send to shared personal pairing code
    if (_pairingCode.isNotEmpty) {
      await sendDirectToTopic(
        _pairingCode,
        _pairingSecret,
        msg,
        relayHost: _customRelayHost,
      );
      dispatched = true;
    }

    // 4. Send via active local socket
    sendMessage(msg);

    // Also request fresh state from player
    requestStateFromPlayer(targetPartner: partner);

    notifyListeners();
    return dispatched;
  }

  /// Forces a complete re-sync of all active directives and requests the submissive's dashboard state
  Future<void> forceResyncDashboard({PartnerContact? targetPartner}) async {
    requestStateFromPlayer(targetPartner: targetPartner);

    // Re-transmit any unconfirmed active directives
    for (final active in _remoteActiveOrders) {
      if (!isOrderConfirmedOnPlayer(active) && active.status != OrderStatus.failed) {
        await resendDispatchedOrder(active, targetPartner: targetPartner);
      }
    }

    // Re-transmit any unconfirmed active quests
    if (_questService != null) {
      for (final entry in _questService!.remotePlayerQuests.entries) {
        final activeQuest = entry.value;
        if (!activeQuest.isCompleted && !isQuestConfirmedOnPlayer(activeQuest.quest.id, activeQuest.quest.title)) {
          resendDispatchedQuest(entry.key, activeQuest.quest, targetPartner: targetPartner);
        }
      }
    }

    notifyListeners();
  }

  bool dispatchQuestToPlayer(Quest quest, {PartnerContact? targetPartner}) {
    final myDisplayName = _nickname.isNotEmpty
        ? _nickname
        : (_role == ConnectionRole.director ? 'Director' : 'Dominant');

    // 0. Direct to Self (This Device)
    final isDirectToSelf = (targetPartner != null && targetPartner.isSelf) ||
        (targetPartner == null &&
            _partnerService?.activePartner == null &&
            (_partnerService?.unblockedContacts.isEmpty ?? true) &&
            _pairingCode.isEmpty);

    if (isDirectToSelf) {
      _questService?.assignQuestFromDirector(
        quest,
        directorName: myDisplayName.isNotEmpty ? '$myDisplayName (Self)' : 'Self (Director)',
        directorCode: _pairingCode,
      );
      _confirmedOnPlayerQuestIds.add(quest.id);
      _confirmedOnPlayerQuestIds.add(quest.title.trim().toLowerCase());
      _saveConfirmedQuests();
      try {
        NotificationService.showOrderDispatchedNotification(
          title: 'Quest: ${quest.title}',
          description: '${quest.steps.length} chained directives assigned.',
          assignerName: myDisplayName.isNotEmpty ? '$myDisplayName (Self)' : 'Self (Director)',
          rewardTokens: quest.bonusTokensOnComplete,
        );
      } catch (_) {}
      try {
        SoundService.playAlarm();
      } catch (_) {}
      notifyListeners();
      return true;
    }

    final msg = SyncMessage(
      id: const Uuid().v4(),
      type: SyncMessageType.dispatchQuest,
      senderId: _deviceId,
      payload: {
        'quest': quest.toJson(),
        'senderCode': _pairingCode,
        'senderId': _deviceId,
        'senderName': myDisplayName,
      },
    );

    bool dispatched = false;

    // 1. Direct to selected partner contact if explicitly targeted
    if (targetPartner != null && !targetPartner.isSelf && targetPartner.pairingCode.isNotEmpty) {
      sendDirectToTopic(
        targetPartner.pairingCode,
        targetPartner.pairingSecret,
        msg,
        relayHost: targetPartner.customRelayHost.isNotEmpty ? targetPartner.customRelayHost : _customRelayHost,
      );
      dispatched = true;
    } else {
      // 2. Direct to active partner contact
      final active = _partnerService?.activePartner;
      if (active != null && active.pairingCode.isNotEmpty) {
        sendDirectToTopic(
          active.pairingCode,
          active.pairingSecret,
          msg,
          relayHost: active.customRelayHost.isNotEmpty ? active.customRelayHost : _customRelayHost,
        );
        dispatched = true;
      }

      // 3. Fall back to broadcasting to all unblocked submissive and peer contacts
      final recipients = _partnerService?.unblockedContacts
          .where((c) => c.role == PartnerRole.submissive || c.role == PartnerRole.peer)
          .toList() ?? [];
      for (final p in recipients) {
        if (p.id != active?.id && p.pairingCode.isNotEmpty) {
          sendDirectToTopic(
            p.pairingCode,
            p.pairingSecret,
            msg,
            relayHost: p.customRelayHost.isNotEmpty ? p.customRelayHost : _customRelayHost,
          );
          dispatched = true;
        }
      }

      // 4. Send to shared personal pairing code
      if (_pairingCode.isNotEmpty) {
        sendDirectToTopic(
          _pairingCode,
          _pairingSecret,
          msg,
          relayHost: _customRelayHost,
        );
        dispatched = true;
      }
    }

    sendMessage(msg);

    // Retain dispatched quest copy on Director side for real-time progress monitoring
    final active = _partnerService?.activePartner;
    final recipientKey = targetPartner?.id ?? targetPartner?.pairingCode ?? active?.id ?? active?.pairingCode ?? 'remote_player';
    _questService?.recordDispatchedQuest(
      recipientKey,
      quest,
      partnerName: targetPartner?.displayName ?? active?.displayName ?? 'Submissive',
      partnerCode: targetPartner?.pairingCode ?? active?.pairingCode ?? '',
    );

    notifyListeners();
    return dispatched;
  }

  /// Re-transmits an unconfirmed quest playlist to a specific recipient
  bool resendDispatchedQuest(String partnerKey, Quest quest, {PartnerContact? targetPartner}) {
    PartnerContact? recipient = targetPartner;
    if (recipient == null && _partnerService != null) {
      recipient = _partnerService!.findContactById(partnerKey) ??
          _partnerService!.findContactByCode(partnerKey) ??
          _partnerService!.activePartner;
    }
    return dispatchQuestToPlayer(quest, targetPartner: recipient);
  }

  /// Sends quest step progression directly to Director's topic over relay
  Future<bool> notifyQuestStepCompleted(Quest quest, QuestStep step, int stepIndex, int totalSteps, {int tokensAwarded = 0}) async {
    final senderName = _nickname.isNotEmpty ? _nickname : 'Player';
    final msg = SyncMessage(
      id: const Uuid().v4(),
      type: SyncMessageType.questStepCompleted,
      senderId: _deviceId,
      payload: {
        'questId': quest.id,
        'questTitle': quest.title,
        'stepIndex': stepIndex,
        'stepTitle': step.title,
        'totalSteps': totalSteps,
        'tokensAwarded': tokensAwarded,
        'senderName': senderName,
        'senderCode': _pairingCode,
      },
    );

    bool sent = false;

    // 1. Direct to assigning Director's code if recorded
    final assignerCode = _questService?.activeQuest?.assignedByPartnerCode;
    if (assignerCode != null && assignerCode.isNotEmpty) {
      final assignerContact = _partnerService?.findContactByCode(assignerCode);
      await sendDirectToTopic(
        assignerCode,
        assignerContact?.pairingSecret ?? _pairingSecret,
        msg,
        relayHost: assignerContact?.customRelayHost.isNotEmpty == true ? assignerContact!.customRelayHost : _customRelayHost,
      );
      sent = true;
    }

    // 2. Direct to all unblocked dominant and peer partners
    final recipients = _partnerService?.unblockedContacts
        .where((c) => (c.role == PartnerRole.dominant || c.role == PartnerRole.peer) && c.pairingCode != assignerCode)
        .toList() ?? [];
    for (final partner in recipients) {
      if (partner.pairingCode.isNotEmpty) {
        await sendDirectToTopic(
          partner.pairingCode,
          partner.pairingSecret,
          msg,
          relayHost: partner.customRelayHost.isNotEmpty ? partner.customRelayHost : _customRelayHost,
        );
        sent = true;
      }
    }

    final active = _partnerService?.activePartner;
    if (active != null && active.pairingCode != assignerCode && !recipients.any((d) => d.id == active.id) && active.pairingCode.isNotEmpty) {
      await sendDirectToTopic(
        active.pairingCode,
        active.pairingSecret,
        msg,
        relayHost: active.customRelayHost.isNotEmpty ? active.customRelayHost : _customRelayHost,
      );
      sent = true;
    }

    sendMessage(msg);
    broadcastPlayerState();
    return sent;
  }

  /// Sends grand quest completion directly to Director's topic over relay
  Future<bool> notifyQuestCompleted(Quest quest, {int bonusTokens = 0}) async {
    final senderName = _nickname.isNotEmpty ? _nickname : 'Player';
    final msg = SyncMessage(
      id: const Uuid().v4(),
      type: SyncMessageType.questCompleted,
      senderId: _deviceId,
      payload: {
        'questId': quest.id,
        'questTitle': quest.title,
        'totalSteps': quest.steps.length,
        'bonusTokens': bonusTokens,
        'senderName': senderName,
        'senderCode': _pairingCode,
      },
    );

    bool sent = false;

    // 1. Direct to assigning Director's code if recorded
    final assignerCode = _questService?.activeQuest?.assignedByPartnerCode;
    if (assignerCode != null && assignerCode.isNotEmpty) {
      final assignerContact = _partnerService?.findContactByCode(assignerCode);
      await sendDirectToTopic(
        assignerCode,
        assignerContact?.pairingSecret ?? _pairingSecret,
        msg,
        relayHost: assignerContact?.customRelayHost.isNotEmpty == true ? assignerContact!.customRelayHost : _customRelayHost,
      );
      sent = true;
    }

    // 2. Direct to all unblocked dominant and peer partners
    final recipients = _partnerService?.unblockedContacts
        .where((c) => (c.role == PartnerRole.dominant || c.role == PartnerRole.peer) && c.pairingCode != assignerCode)
        .toList() ?? [];
    for (final partner in recipients) {
      if (partner.pairingCode.isNotEmpty) {
        await sendDirectToTopic(
          partner.pairingCode,
          partner.pairingSecret,
          msg,
          relayHost: partner.customRelayHost.isNotEmpty ? partner.customRelayHost : _customRelayHost,
        );
        sent = true;
      }
    }

    final active = _partnerService?.activePartner;
    if (active != null && active.pairingCode != assignerCode && !recipients.any((d) => d.id == active.id) && active.pairingCode.isNotEmpty) {
      await sendDirectToTopic(
        active.pairingCode,
        active.pairingSecret,
        msg,
        relayHost: active.customRelayHost.isNotEmpty ? active.customRelayHost : _customRelayHost,
      );
      sent = true;
    }

    sendMessage(msg);
    broadcastPlayerState();
    return sent;
  }

  bool sendPackToPlayer(OrderPack pack, {PartnerContact? targetPartner}) {
    final msg = SyncMessage(
      id: Uuid().v4(),
      type: SyncMessageType.syncPacks,
      senderId: _deviceId,
      payload: {'pack': pack.toJson()},
    );

    if (targetPartner != null) {
      sendDirectToTopic(
        targetPartner.pairingCode,
        targetPartner.pairingSecret,
        msg,
        relayHost: targetPartner.customRelayHost.isNotEmpty ? targetPartner.customRelayHost : _customRelayHost,
      );
      return true;
    }

    final active = _partnerService?.activePartner;
    if (active != null) {
      sendDirectToTopic(
        active.pairingCode,
        active.pairingSecret,
        msg,
        relayHost: active.customRelayHost.isNotEmpty ? active.customRelayHost : _customRelayHost,
      );
      return true;
    }

    return sendMessage(msg);
  }

  /// Internal helper to route proof review responses back to the original submitter
  void _sendToProofSender(String activeOrderId, SyncMessage msg, {PartnerContact? targetPartner}) {
    // 1. If explicit partner provided, send to them
    if (targetPartner != null) {
      sendDirectToTopic(
        targetPartner.pairingCode,
        targetPartner.pairingSecret,
        msg,
        relayHost: targetPartner.customRelayHost.isNotEmpty ? targetPartner.customRelayHost : _customRelayHost,
      );
      return;
    }

    // 2. Look up the sender who originally submitted the proof using tracked info
    PartnerContact? senderPartner;
    final trackedSenderId = _remoteReviewSenderId[activeOrderId];
    final trackedSenderCode = _remoteReviewSenderCode[activeOrderId];

    if (trackedSenderId != null && trackedSenderId.isNotEmpty) {
      senderPartner = _partnerService?.findContactById(trackedSenderId);
    }
    if (senderPartner == null && trackedSenderCode != null && trackedSenderCode.isNotEmpty) {
      senderPartner = _partnerService?.findContactByCode(trackedSenderCode);
    }

    if (senderPartner != null) {
      sendDirectToTopic(
        senderPartner.pairingCode,
        senderPartner.pairingSecret,
        msg,
        relayHost: senderPartner.customRelayHost.isNotEmpty ? senderPartner.customRelayHost : _customRelayHost,
      );
      return;
    }

    // 3. If we have the sender's pairing code but couldn't find them in contacts,
    //    try sending directly using the code (less reliable but a good fallback)
    if (trackedSenderCode != null && trackedSenderCode.isNotEmpty) {
      sendDirectToTopic(
        trackedSenderCode,
        _pairingSecret,
        msg,
      );
      return;
    }

    // 4. Fall back to broadcasting to all submissive contacts
    final submissives = _partnerService?.unblockedContacts
        .where((c) => c.role == PartnerRole.submissive)
        .toList() ?? [];
    if (submissives.isNotEmpty) {
      for (final p in submissives) {
        sendDirectToTopic(
          p.pairingCode,
          p.pairingSecret,
          msg,
          relayHost: p.customRelayHost.isNotEmpty ? p.customRelayHost : _customRelayHost,
        );
      }
      return;
    }

    // 5. Last resort: active partner
    final active = _partnerService?.activePartner;
    if (active != null) {
      sendDirectToTopic(
        active.pairingCode,
        active.pairingSecret,
        msg,
        relayHost: active.customRelayHost.isNotEmpty ? active.customRelayHost : _customRelayHost,
      );
    }
  }

  bool approvePlayerProof(String activeOrderId, {String? note, PartnerContact? targetPartner}) {
    final msg = SyncMessage(
      id: Uuid().v4(),
      type: SyncMessageType.approveProof,
      senderId: _deviceId,
      payload: {
        'activeOrderId': activeOrderId,
        'directorNote': note,
      },
    );

    _sendToProofSender(activeOrderId, msg, targetPartner: targetPartner);

    _remoteReviewOrders.removeWhere((o) => o.id == activeOrderId);
    _remoteActiveOrders.removeWhere((o) => o.id == activeOrderId);
    _remoteReviewSenderCode.remove(activeOrderId);
    _remoteReviewSenderId.remove(activeOrderId);
    _saveDirectorDispatchedOrders();
    notifyListeners();
    return true;
  }

  bool rejectPlayerProof(
    String activeOrderId, {
    String reason = 'Rejected by Director',
    bool returnToQueue = false,
    PartnerContact? targetPartner,
  }) {
    final reviewIdx = _remoteReviewOrders.indexWhere((o) => o.id == activeOrderId);
    final reviewOrder = reviewIdx != -1 ? _remoteReviewOrders[reviewIdx] : null;

    final msg = SyncMessage(
      id: const Uuid().v4(),
      type: SyncMessageType.rejectProof,
      senderId: _deviceId,
      payload: {
        'activeOrderId': activeOrderId,
        'reason': reason,
        'returnToQueue': returnToQueue,
        'orderTitle': reviewOrder?.order.title,
      },
    );

    _sendToProofSender(activeOrderId, msg, targetPartner: targetPartner);

    _remoteReviewOrders.removeWhere((o) => o.id == activeOrderId);
    _remoteReviewSenderCode.remove(activeOrderId);
    _remoteReviewSenderId.remove(activeOrderId);

    if (returnToQueue && reviewOrder != null) {
      // Put back in remoteActiveOrders with status active and reset proof
      final returned = reviewOrder.returnedToQueue(reason: reason);
      _remoteActiveOrders.removeWhere((o) =>
          o.id == activeOrderId ||
          (o.order.id.isNotEmpty && o.order.id == returned.order.id) ||
          o.order.title.trim().toLowerCase() == returned.order.title.trim().toLowerCase());
      _remoteActiveOrders.insert(0, returned);
    } else {
      _remoteActiveOrders.removeWhere((o) =>
          o.id == activeOrderId ||
          (reviewOrder != null && reviewOrder.order.id.isNotEmpty && o.order.id == reviewOrder.order.id) ||
          (reviewOrder != null && o.order.title.trim().toLowerCase() == reviewOrder.order.title.trim().toLowerCase()));
    }

    _saveDirectorDispatchedOrders();
    notifyListeners();
    return true;
  }

  bool adjustPlayerTokens(int delta, String reason, {PartnerContact? targetPartner}) {
    final msg = SyncMessage(
      id: Uuid().v4(),
      type: SyncMessageType.adjustTokens,
      senderId: _deviceId,
      payload: {
        'delta': delta,
        'reason': reason,
      },
    );

    if (targetPartner != null) {
      sendDirectToTopic(
        targetPartner.pairingCode,
        targetPartner.pairingSecret,
        msg,
        relayHost: targetPartner.customRelayHost.isNotEmpty ? targetPartner.customRelayHost : _customRelayHost,
      );
      return true;
    }

    final active = _partnerService?.activePartner;
    if (active != null) {
      sendDirectToTopic(
        active.pairingCode,
        active.pairingSecret,
        msg,
        relayHost: active.customRelayHost.isNotEmpty ? active.customRelayHost : _customRelayHost,
      );
      return true;
    }

    return sendMessage(msg);
  }

  Future<void> disconnect({bool explicit = true}) async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    if (explicit) {
      _autoConnect = false;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('pairing_auto_connect', false);
      } catch (_) {}
    }

    await _socketSubscription?.cancel();
    await _socket?.close();
    await _server?.close(force: true);
    _socket = null;
    _server = null;

    await _cloudSubscription?.cancel();
    await _cloudSocket?.close();
    _cloudSocket = null;

    _remoteActiveOrders.clear();
    _remoteReviewOrders.clear();
    _remotePendingRedemptions.clear();

    _status = ConnectionStatus.disconnected;
    if (explicit) _role = ConnectionRole.none;
    _statusMessage = explicit ? 'Disconnected' : 'Reconnecting in background...';
    if (!_isDisposed) notifyListeners();
  }

  bool _isDisposed = false;

  @override
  void notifyListeners() {
    if (!_isDisposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _reconnectTimer?.cancel();
    _bgDrainTimer?.cancel();
    _broadcastDebounceTimer?.cancel();
    _heartbeatTimer?.cancel();
    _engine.removeListener(_onEngineChanged);
    _incomingOrderController.close();
    _socketSubscription?.cancel();
    _socket?.close();
    _server?.close(force: true);
    _cloudSubscription?.cancel();
    _cloudSocket?.close();
    _httpClient.close(force: true);
    super.dispose();
  }
}
