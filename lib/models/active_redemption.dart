import 'package:uuid/uuid.dart';
import 'reward_item.dart';

enum RedemptionStatus {
  pending,  // Awaiting dominant review
  approved, // Approved and usable
  claimed,  // Claimed / redeemed immediately
  rejected, // Rejected (tokens refunded)
}

class ActiveRedemption {
  final String id;
  final RewardItem reward;
  final DateTime requestedAt;
  final DateTime? resolvedAt;
  final RedemptionStatus status;
  final String? note;
  final String? directorNote;

  ActiveRedemption({
    String? id,
    required this.reward,
    DateTime? requestedAt,
    this.resolvedAt,
    this.status = RedemptionStatus.claimed,
    this.note,
    this.directorNote,
  })  : id = id ?? const Uuid().v4(),
        requestedAt = requestedAt ?? DateTime.now();

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'reward': reward.toJson(),
      'requestedAt': requestedAt.toIso8601String(),
      'resolvedAt': resolvedAt?.toIso8601String(),
      'status': status.name,
      'note': note,
      'directorNote': directorNote,
    };
  }

  factory ActiveRedemption.fromJson(Map<String, dynamic> json) {
    return ActiveRedemption(
      id: json['id'] as String?,
      reward: RewardItem.fromJson(json['reward'] as Map<String, dynamic>),
      requestedAt: json['requestedAt'] != null
          ? DateTime.parse(json['requestedAt'] as String)
          : DateTime.now(),
      resolvedAt: json['resolvedAt'] != null
          ? DateTime.parse(json['resolvedAt'] as String)
          : null,
      status: RedemptionStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => RedemptionStatus.claimed,
      ),
      note: json['note'] as String?,
      directorNote: json['directorNote'] as String?,
    );
  }

  ActiveRedemption copyWith({
    String? id,
    RewardItem? reward,
    DateTime? requestedAt,
    DateTime? resolvedAt,
    RedemptionStatus? status,
    String? note,
    String? directorNote,
  }) {
    return ActiveRedemption(
      id: id ?? this.id,
      reward: reward ?? this.reward,
      requestedAt: requestedAt ?? this.requestedAt,
      resolvedAt: resolvedAt ?? this.resolvedAt,
      status: status ?? this.status,
      note: note ?? this.note,
      directorNote: directorNote ?? this.directorNote,
    );
  }
}
