import 'package:uuid/uuid.dart';

class ChatMessage {
  final String id;
  final String partnerId;
  final String senderId;
  final String senderName;
  final String text;
  final String? imageBase64;
  final DateTime timestamp;
  final bool isOutgoing;
  final bool isRead;
  final bool isEdited;
  final DateTime? editedTimestamp;
  final String? packType; // 'orderPack', 'rewardPack', 'questPack', 'quest'
  final String? packData; // JSON serialized string of the pack
  final String? packTitle; // Display title of the pack
  final int? packItemCount; // Number of items / steps in the pack
  final bool isEncryptedPack; // Whether the pack payload is password encrypted

  ChatMessage({
    String? id,
    required this.partnerId,
    required this.senderId,
    this.senderName = '',
    this.text = '',
    this.imageBase64,
    DateTime? timestamp,
    this.isOutgoing = false,
    this.isRead = false,
    this.isEdited = false,
    this.editedTimestamp,
    this.packType,
    this.packData,
    this.packTitle,
    this.packItemCount,
    this.isEncryptedPack = false,
  })  : id = id ?? const Uuid().v4(),
        timestamp = timestamp ?? DateTime.now();

  bool get isPackTransfer => packType != null && packData != null && packData!.isNotEmpty;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'partnerId': partnerId,
      'senderId': senderId,
      'senderName': senderName,
      'text': text,
      'imageBase64': imageBase64,
      'timestamp': timestamp.toIso8601String(),
      'isOutgoing': isOutgoing,
      'isRead': isRead,
      'isEdited': isEdited,
      'editedTimestamp': editedTimestamp?.toIso8601String(),
      'packType': packType,
      'packData': packData,
      'packTitle': packTitle,
      'packItemCount': packItemCount,
      'isEncryptedPack': isEncryptedPack,
    };
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String?,
      partnerId: json['partnerId'] as String? ?? '',
      senderId: json['senderId'] as String? ?? '',
      senderName: json['senderName'] as String? ?? '',
      text: json['text'] as String? ?? '',
      imageBase64: json['imageBase64'] as String?,
      timestamp: json['timestamp'] != null
          ? DateTime.tryParse(json['timestamp'] as String) ?? DateTime.now()
          : DateTime.now(),
      isOutgoing: json['isOutgoing'] as bool? ?? false,
      isRead: json['isRead'] as bool? ?? false,
      isEdited: json['isEdited'] as bool? ?? false,
      editedTimestamp: json['editedTimestamp'] != null
          ? DateTime.tryParse(json['editedTimestamp'] as String)
          : null,
      packType: json['packType'] as String?,
      packData: json['packData'] as String?,
      packTitle: json['packTitle'] as String?,
      packItemCount: (json['packItemCount'] as num?)?.toInt(),
      isEncryptedPack: json['isEncryptedPack'] as bool? ?? false,
    );
  }

  ChatMessage copyWith({
    String? id,
    String? partnerId,
    String? senderId,
    String? senderName,
    String? text,
    String? imageBase64,
    DateTime? timestamp,
    bool? isOutgoing,
    bool? isRead,
    bool? isEdited,
    DateTime? editedTimestamp,
    String? packType,
    String? packData,
    String? packTitle,
    int? packItemCount,
    bool? isEncryptedPack,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      partnerId: partnerId ?? this.partnerId,
      senderId: senderId ?? this.senderId,
      senderName: senderName ?? this.senderName,
      text: text ?? this.text,
      imageBase64: imageBase64 ?? this.imageBase64,
      timestamp: timestamp ?? this.timestamp,
      isOutgoing: isOutgoing ?? this.isOutgoing,
      isRead: isRead ?? this.isRead,
      isEdited: isEdited ?? this.isEdited,
      editedTimestamp: editedTimestamp ?? this.editedTimestamp,
      packType: packType ?? this.packType,
      packData: packData ?? this.packData,
      packTitle: packTitle ?? this.packTitle,
      packItemCount: packItemCount ?? this.packItemCount,
      isEncryptedPack: isEncryptedPack ?? this.isEncryptedPack,
    );
  }
}
