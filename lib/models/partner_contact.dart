import 'package:uuid/uuid.dart';

enum PartnerRole { submissive, dominant, peer }

class PartnerContact {
  final String id;
  final String displayName;
  final String pairingCode;
  final String pairingSecret;
  final PartnerRole role;
  final bool isBlocked;
  final String customRelayHost;
  final DateTime? lastSeen;
  final int unreadCount;
  final int avatarColorIndex;
  final String? notes;
  final DateTime createdAt;

  PartnerContact({
    String? id,
    required this.displayName,
    required this.pairingCode,
    required this.pairingSecret,
    this.role = PartnerRole.submissive,
    this.isBlocked = false,
    this.customRelayHost = 'ntfy.envs.net',
    this.lastSeen,
    this.unreadCount = 0,
    this.avatarColorIndex = 0,
    this.notes,
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now();

  static const String selfId = '__self__';

  static PartnerContact self({String displayName = 'Myself (This Device)'}) {
    return PartnerContact(
      id: selfId,
      displayName: displayName,
      pairingCode: '',
      pairingSecret: '',
      role: PartnerRole.submissive,
    );
  }

  bool get isSelf => id == selfId;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'displayName': displayName,
      'pairingCode': pairingCode,
      'pairingSecret': pairingSecret,
      'role': role.name,
      'isBlocked': isBlocked,
      'customRelayHost': customRelayHost,
      'lastSeen': lastSeen?.toIso8601String(),
      'unreadCount': unreadCount,
      'avatarColorIndex': avatarColorIndex,
      'notes': notes,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory PartnerContact.fromJson(Map<String, dynamic> json) {
    return PartnerContact(
      id: json['id'] as String?,
      displayName: json['displayName'] as String? ?? 'Partner',
      pairingCode: json['pairingCode'] as String? ?? '',
      pairingSecret: json['pairingSecret'] as String? ?? '',
      role: PartnerRole.values.firstWhere(
        (e) => e.name == json['role'],
        orElse: () => PartnerRole.submissive,
      ),
      isBlocked: json['isBlocked'] as bool? ?? false,
      customRelayHost: json['customRelayHost'] as String? ?? 'ntfy.envs.net',
      lastSeen: json['lastSeen'] != null ? DateTime.tryParse(json['lastSeen'] as String) : null,
      unreadCount: (json['unreadCount'] as num?)?.toInt() ?? 0,
      avatarColorIndex: (json['avatarColorIndex'] as num?)?.toInt() ?? 0,
      notes: json['notes'] as String?,
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String)
          : null,
    );
  }

  PartnerContact copyWith({
    String? id,
    String? displayName,
    String? pairingCode,
    String? pairingSecret,
    PartnerRole? role,
    bool? isBlocked,
    String? customRelayHost,
    DateTime? lastSeen,
    int? unreadCount,
    int? avatarColorIndex,
    String? notes,
    DateTime? createdAt,
  }) {
    return PartnerContact(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      pairingCode: pairingCode ?? this.pairingCode,
      pairingSecret: pairingSecret ?? this.pairingSecret,
      role: role ?? this.role,
      isBlocked: isBlocked ?? this.isBlocked,
      customRelayHost: customRelayHost ?? this.customRelayHost,
      lastSeen: lastSeen ?? this.lastSeen,
      unreadCount: unreadCount ?? this.unreadCount,
      avatarColorIndex: avatarColorIndex ?? this.avatarColorIndex,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PartnerContact &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
