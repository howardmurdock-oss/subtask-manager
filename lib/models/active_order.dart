import 'package:uuid/uuid.dart';
import 'order_item.dart';

enum OrderStatus {
  pending,      // Received or queued, waiting to be started
  active,       // In progress
  paused,       // Paused (if permitted)
  underReview,  // Proof submitted, waiting for dominant approval
  completed,    // Successfully finished
  failed,       // Expired or forfeited
  cancelled,    // Aborted by director
  emergencyCleared, // Dismissed / cleared by player
}

class ActiveOrder {
  final String id;
  final OrderItem order;
  final DateTime assignedAt;
  final DateTime? expiresAt;
  final DateTime? completedAt;
  final OrderStatus status;
  final int timeSpentSeconds;
  final int actionSecondsRemaining;
  final bool isActionTimerRunning;
  final bool isActionTimerFinished;
  final DateTime? actionTimerEndsAt;
  final String? submissionProof;
  final String? proofImageBase64;
  final String? directorNote;
  final bool assignedByDirector;
  final String? assignedByPartnerCode;
  final String? assignedByPartnerId;
  final String? assignedByPartnerName;

  ActiveOrder({
    String? id,
    required this.order,
    DateTime? assignedAt,
    this.expiresAt,
    this.completedAt,
    this.status = OrderStatus.active,
    this.timeSpentSeconds = 0,
    int? actionSecondsRemaining,
    this.isActionTimerRunning = false,
    this.isActionTimerFinished = false,
    this.actionTimerEndsAt,
    this.submissionProof,
    this.proofImageBase64,
    this.directorNote,
    this.assignedByDirector = false,
    this.assignedByPartnerCode,
    this.assignedByPartnerId,
    this.assignedByPartnerName,
  })  : id = id ?? const Uuid().v4(),
        assignedAt = assignedAt ?? DateTime.now(),
        actionSecondsRemaining = actionSecondsRemaining ?? order.actionDurationSeconds;

  /// Formats the directive assignment time in clean, human-readable format
  static String formatAssignedTime(DateTime dt) {
    final now = DateTime.now();
    final local = dt.toLocal();
    final hour = local.hour == 0 ? 12 : (local.hour > 12 ? local.hour - 12 : local.hour);
    final minute = local.minute.toString().padLeft(2, '0');
    final amPm = local.hour >= 12 ? 'PM' : 'AM';
    final timeStr = '$hour:$minute $amPm';

    final isToday = local.year == now.year && local.month == now.month && local.day == now.day;
    if (isToday) {
      return 'Today, $timeStr';
    }
    final yesterday = now.subtract(const Duration(days: 1));
    final isYesterday = local.year == yesterday.year && local.month == yesterday.month && local.day == yesterday.day;
    if (isYesterday) {
      return 'Yesterday, $timeStr';
    }
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[local.month - 1]} ${local.day}, $timeStr';
  }

  /// Returns the live dynamic seconds remaining on the physical routine timer
  int get currentActionSecondsRemaining {
    if (isActionTimerFinished) return 0;
    if (isActionTimerRunning && actionTimerEndsAt != null) {
      final diff = actionTimerEndsAt!.difference(DateTime.now()).inSeconds;
      return diff > 0 ? diff : 0;
    }
    return actionSecondsRemaining;
  }

  int get remainingSeconds {
    if (expiresAt == null) return 0;
    final diff = expiresAt!.difference(DateTime.now()).inSeconds;
    return diff > 0 ? diff : 0;
  }

  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!) &&
        (status == OrderStatus.active || status == OrderStatus.pending);
  }

  double get deadlineProgressPercentage {
    if (expiresAt == null || order.durationMinutes <= 0) {
      return status == OrderStatus.completed ? 1.0 : 0.0;
    }
    final totalSeconds = order.durationMinutes * 60;
    if (totalSeconds == 0) return 1.0;
    final remaining = remainingSeconds;
    final elapsed = totalSeconds - remaining;
    return (elapsed / totalSeconds).clamp(0.0, 1.0);
  }

  double get actionTimerProgressPercentage {
    if (order.actionDurationSeconds <= 0) return 1.0;
    final elapsed = order.actionDurationSeconds - currentActionSecondsRemaining;
    return (elapsed / order.actionDurationSeconds).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'order': order.toJson(),
      'assignedAt': assignedAt.toIso8601String(),
      'expiresAt': expiresAt?.toIso8601String(),
      'completedAt': completedAt?.toIso8601String(),
      'status': status.name,
      'timeSpentSeconds': timeSpentSeconds,
      'actionSecondsRemaining': actionSecondsRemaining,
      'isActionTimerRunning': isActionTimerRunning,
      'isActionTimerFinished': isActionTimerFinished,
      'actionTimerEndsAt': actionTimerEndsAt?.toIso8601String(),
      'submissionProof': submissionProof,
      'proofImageBase64': proofImageBase64,
      'directorNote': directorNote,
      'assignedByDirector': assignedByDirector,
      'assignedByPartnerCode': assignedByPartnerCode,
      'assignedByPartnerId': assignedByPartnerId,
      'assignedByPartnerName': assignedByPartnerName,
    };
  }

  factory ActiveOrder.fromJson(Map<String, dynamic> json) {
    final order = OrderItem.fromJson(json['order'] as Map<String, dynamic>);
    return ActiveOrder(
      id: json['id'] as String?,
      order: order,
      assignedAt: json['assignedAt'] != null
          ? DateTime.parse(json['assignedAt'] as String)
          : DateTime.now(),
      expiresAt: json['expiresAt'] != null
          ? DateTime.parse(json['expiresAt'] as String)
          : null,
      completedAt: json['completedAt'] != null
          ? DateTime.parse(json['completedAt'] as String)
          : null,
      status: OrderStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => OrderStatus.active,
      ),
      timeSpentSeconds: (json['timeSpentSeconds'] as num?)?.toInt() ?? 0,
      actionSecondsRemaining: (json['actionSecondsRemaining'] as num?)?.toInt() ?? order.actionDurationSeconds,
      isActionTimerRunning: json['isActionTimerRunning'] as bool? ?? false,
      isActionTimerFinished: json['isActionTimerFinished'] as bool? ?? false,
      actionTimerEndsAt: json['actionTimerEndsAt'] != null
          ? DateTime.parse(json['actionTimerEndsAt'] as String)
          : null,
      submissionProof: json['submissionProof'] as String?,
      proofImageBase64: json['proofImageBase64'] as String?,
      directorNote: json['directorNote'] as String?,
      assignedByDirector: json['assignedByDirector'] as bool? ?? false,
      assignedByPartnerCode: json['assignedByPartnerCode'] as String?,
      assignedByPartnerId: json['assignedByPartnerId'] as String?,
      assignedByPartnerName: json['assignedByPartnerName'] as String?,
    );
  }

  ActiveOrder copyWith({
    String? id,
    OrderItem? order,
    DateTime? assignedAt,
    DateTime? expiresAt,
    DateTime? completedAt,
    OrderStatus? status,
    int? timeSpentSeconds,
    int? actionSecondsRemaining,
    bool? isActionTimerRunning,
    bool? isActionTimerFinished,
    DateTime? actionTimerEndsAt,
    bool clearActionTimerEndsAt = false,
    String? submissionProof,
    String? proofImageBase64,
    String? directorNote,
    bool clearDirectorNote = false,
    bool? assignedByDirector,
    String? assignedByPartnerCode,
    String? assignedByPartnerId,
    String? assignedByPartnerName,
  }) {
    return ActiveOrder(
      id: id ?? this.id,
      order: order ?? this.order,
      assignedAt: assignedAt ?? this.assignedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      completedAt: completedAt ?? this.completedAt,
      status: status ?? this.status,
      timeSpentSeconds: timeSpentSeconds ?? this.timeSpentSeconds,
      actionSecondsRemaining: actionSecondsRemaining ?? this.actionSecondsRemaining,
      isActionTimerRunning: isActionTimerRunning ?? this.isActionTimerRunning,
      isActionTimerFinished: isActionTimerFinished ?? this.isActionTimerFinished,
      actionTimerEndsAt: clearActionTimerEndsAt ? null : (actionTimerEndsAt ?? this.actionTimerEndsAt),
      submissionProof: submissionProof ?? this.submissionProof,
      proofImageBase64: proofImageBase64 ?? this.proofImageBase64,
      directorNote: clearDirectorNote ? null : (directorNote ?? this.directorNote),
      assignedByDirector: assignedByDirector ?? this.assignedByDirector,
      assignedByPartnerCode: assignedByPartnerCode ?? this.assignedByPartnerCode,
      assignedByPartnerId: assignedByPartnerId ?? this.assignedByPartnerId,
      assignedByPartnerName: assignedByPartnerName ?? this.assignedByPartnerName,
    );
  }

  /// Create a copy returned back to the active queue with proof and timers reset
  ActiveOrder returnedToQueue({String? reason}) {
    return ActiveOrder(
      id: id,
      order: order,
      assignedAt: assignedAt,
      expiresAt: expiresAt,
      completedAt: null,
      status: OrderStatus.active,
      timeSpentSeconds: timeSpentSeconds,
      actionSecondsRemaining: order.actionDurationSeconds,
      isActionTimerRunning: false,
      isActionTimerFinished: false,
      submissionProof: null,
      proofImageBase64: null,
      directorNote: reason ?? directorNote,
      assignedByDirector: assignedByDirector,
      assignedByPartnerCode: assignedByPartnerCode,
      assignedByPartnerId: assignedByPartnerId,
      assignedByPartnerName: assignedByPartnerName,
    );
  }
}
