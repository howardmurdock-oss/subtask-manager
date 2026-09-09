import 'dart:convert';
import 'package:uuid/uuid.dart';

enum SyncMessageType {
  ping,
  pong,
  pairingRequest,
  pairingAccept,
  pairingDecline,
  dispatchOrder,
  dispatchOrderAck,
  orderStatusUpdate,
  submitProof,
  approveProof,
  rejectProof,
  adjustTokens,
  syncPacks,
  requestState,
  sendState,
  chatMessage,
  chatEditMessage,
  chatDeleteMessage,
  chatReadReceipt,
  partnerProfile,
  dispatchQuest,
  dispatchQuestAck,
  questStepCompleted,
  questCompleted,
  identityMigrated,
  identityMigratedAck,
}

class SyncMessage {
  final String id;
  final SyncMessageType type;
  final String senderId;
  final String? targetId;

  /// Normalised pairing code of the intended recipient.
  ///
  /// Every device subscribes to its contacts' relay topics, so a topic is not
  /// a private channel — anything published on one is readable by everyone who
  /// has that contact saved. This names who a directed message is actually for
  /// so a receiver can drop what was never addressed to it. Null means an
  /// undirected broadcast (state sync), or a sender too old to set it.
  final String? targetCode;

  final DateTime timestamp;
  final Map<String, dynamic> payload;

  SyncMessage({
    String? id,
    required this.type,
    required this.senderId,
    this.targetId,
    this.targetCode,
    DateTime? timestamp,
    this.payload = const {},
  })  : id = id ?? const Uuid().v4(),
        timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.name,
      'senderId': senderId,
      'targetId': targetId,
      'targetCode': targetCode,
      'timestamp': timestamp.toIso8601String(),
      'payload': payload,
    };
  }

  factory SyncMessage.fromJson(Map<String, dynamic> json) {
    return SyncMessage(
      id: json['id'] as String?,
      type: SyncMessageType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => SyncMessageType.ping,
      ),
      senderId: json['senderId'] as String? ?? 'unknown',
      targetId: json['targetId'] as String?,
      targetCode: json['targetCode'] as String?,
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String)
          : DateTime.now(),
      payload: json['payload'] is Map ? Map<String, dynamic>.from(json['payload'] as Map) : {},
    );
  }

  /// Returns a copy addressed to [code]. Used at the point of transmission so
  /// callers cannot forget to address a directed message.
  SyncMessage withTargetCode(String code) => SyncMessage(
        id: id,
        type: type,
        senderId: senderId,
        targetId: targetId,
        targetCode: code,
        timestamp: timestamp,
        payload: payload,
      );

  String encode() => jsonEncode(toJson());

  factory SyncMessage.decode(String raw) =>
      SyncMessage.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
