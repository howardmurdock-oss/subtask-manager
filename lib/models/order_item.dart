import 'package:uuid/uuid.dart';

enum DurationType {
  instant,            // Complete immediately / untimed
  actionTimer,        // Action timer: Player starts when in position; alarms when done (e.g. 2 min drill)
  deadlineCountdown,  // Deadline countdown: Strict window to finish task before failing (e.g. 30 min)
  actionWithDeadline, // Both action countdown AND a deadline expiration window
  dailyWindow;        // Must complete before end of day

  String get displayName {
    switch (this) {
      case DurationType.instant:
        return 'Instant';
      case DurationType.actionTimer:
        return 'Action Timer';
      case DurationType.deadlineCountdown:
        return 'Countdown';
      case DurationType.actionWithDeadline:
        return 'Action + Deadline';
      case DurationType.dailyWindow:
        return 'Daily Window';
    }
  }
}

enum VerificationType {
  honorCheck,    // Single button tap completion
  noteProof,     // Requires writing a completion report/note
  photoProof,    // Requires photo / image proof submission
  timerOnly;     // Automatically completes when timer reaches zero

  String get displayName {
    switch (this) {
      case VerificationType.honorCheck:
        return 'Honor';
      case VerificationType.noteProof:
        return 'Note';
      case VerificationType.photoProof:
        return 'Photo Proof';
      case VerificationType.timerOnly:
        return 'Timer Only';
    }
  }
}

class OrderItem {
  final String id;
  final String title;
  final String description;
  final String category;
  final int tier; // 1 (Light) to 5 (Demanding)
  final DurationType durationType;
  final int actionDurationSeconds; // For actionTimer: seconds player must perform the task (e.g. 120s)
  final int durationMinutes; // For deadlineCountdown: completion window in minutes
  final int cooldownHours; // Cooldown before it can be pulled again
  final VerificationType verificationType;
  final int rewardTokens;
  final int penaltyTokens;
  final bool isMandatory;
  final bool allowRandomDraw; // If false, excluded from random deck/pool draws (manual Director dispatch only)
  final List<String> tags;
  final List<String> requiredEquipment; // Equipment/items needed (e.g. ['Vibrator', 'Cage'])

  OrderItem({
    String? id,
    required this.title,
    required this.description,
    this.category = 'General',
    this.tier = 1,
    this.durationType = DurationType.instant,
    this.actionDurationSeconds = 0,
    this.durationMinutes = 0,
    this.cooldownHours = 0,
    this.verificationType = VerificationType.honorCheck,
    this.rewardTokens = 10,
    this.penaltyTokens = 20,
    this.isMandatory = false,
    this.allowRandomDraw = true,
    List<String>? tags,
    List<String>? requiredEquipment,
  })  : id = id ?? const Uuid().v4(),
        tags = tags ?? [],
        requiredEquipment = requiredEquipment ?? [];

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'category': category,
      'tier': tier,
      'durationType': durationType.name,
      'actionDurationSeconds': actionDurationSeconds,
      'durationMinutes': durationMinutes,
      'cooldownHours': cooldownHours,
      'verificationType': verificationType.name,
      'rewardTokens': rewardTokens,
      'penaltyTokens': penaltyTokens,
      'isMandatory': isMandatory,
      'allowRandomDraw': allowRandomDraw,
      'tags': tags,
      'requiredEquipment': requiredEquipment,
    };
  }

  factory OrderItem.fromJson(Map<String, dynamic> json) {
    // Backwards compatibility mapping
    var dtName = json['durationType'] as String? ?? 'instant';
    if (dtName == 'timedCountdown') {
      dtName = 'deadlineCountdown';
    }

    final durationType = DurationType.values.firstWhere(
      (e) => e.name == dtName,
      orElse: () => DurationType.instant,
    );

    int actionSeconds = (json['actionDurationSeconds'] as num?)?.toInt() ?? 0;
    int deadlineMins = (json['durationMinutes'] as num?)?.toInt() ?? 0;

    // Fallback if older data stored action time in durationMinutes for actionTimer
    if (durationType == DurationType.actionTimer && actionSeconds == 0 && deadlineMins > 0) {
      actionSeconds = deadlineMins * 60;
    }

    return OrderItem(
      id: json['id'] as String?,
      title: json['title'] as String? ?? 'Untitled Task',
      description: json['description'] as String? ?? '',
      category: json['category'] as String? ?? 'General',
      tier: (json['tier'] as num?)?.toInt() ?? 1,
      durationType: durationType,
      actionDurationSeconds: actionSeconds,
      durationMinutes: deadlineMins,
      cooldownHours: (json['cooldownHours'] as num?)?.toInt() ?? 0,
      verificationType: VerificationType.values.firstWhere(
        (e) => e.name == json['verificationType'],
        orElse: () => VerificationType.honorCheck,
      ),
      rewardTokens: (json['rewardTokens'] as num?)?.toInt() ?? 10,
      penaltyTokens: (json['penaltyTokens'] as num?)?.toInt() ?? 20,
      isMandatory: json['isMandatory'] as bool? ?? false,
      allowRandomDraw: json['allowRandomDraw'] as bool? ?? true,
      tags: (json['tags'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [],
      requiredEquipment: (json['requiredEquipment'] as List<dynamic>?)
              ?.map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList() ??
          [],
    );
  }

  String get formattedTiming {
    switch (durationType) {
      case DurationType.instant:
        return 'Instant';
      case DurationType.actionTimer:
        return '${formatSecondsHuman(actionDurationSeconds)} Action';
      case DurationType.deadlineCountdown:
        return '${formatMinutesHuman(durationMinutes)} Deadline';
      case DurationType.actionWithDeadline:
        final actStr = formatSecondsHuman(actionDurationSeconds);
        final deadStr = formatMinutesHuman(durationMinutes);
        return '$actStr Action ($deadStr Window)';
      case DurationType.dailyWindow:
        return 'Daily Window';
    }
  }

  static String formatSecondsHuman(int totalSeconds) {
    if (totalSeconds <= 0) return '0s';
    if (totalSeconds >= 3600 && totalSeconds % 3600 == 0) {
      return '${totalSeconds ~/ 3600}h';
    }
    if (totalSeconds >= 3600) {
      final h = totalSeconds ~/ 3600;
      final m = (totalSeconds % 3600) ~/ 60;
      final s = totalSeconds % 60;
      if (s > 0) return '${h}h ${m}m ${s}s';
      return '${h}h ${m}m';
    }
    if (totalSeconds >= 60 && totalSeconds % 60 == 0) {
      return '${totalSeconds ~/ 60}m';
    }
    if (totalSeconds >= 60) {
      final m = totalSeconds ~/ 60;
      final s = totalSeconds % 60;
      return '${m}m ${s}s';
    }
    return '${totalSeconds}s';
  }

  static String formatMinutesHuman(int totalMinutes) {
    if (totalMinutes <= 0) return '0m';
    if (totalMinutes >= 60 && totalMinutes % 60 == 0) {
      return '${totalMinutes ~/ 60}h';
    }
    if (totalMinutes >= 60) {
      final h = totalMinutes ~/ 60;
      final m = totalMinutes % 60;
      return '${h}h ${m}m';
    }
    return '${totalMinutes}m';
  }

  OrderItem copyWith({
    String? id,
    String? title,
    String? description,
    String? category,
    int? tier,
    DurationType? durationType,
    int? actionDurationSeconds,
    int? durationMinutes,
    int? cooldownHours,
    VerificationType? verificationType,
    int? rewardTokens,
    int? penaltyTokens,
    bool? isMandatory,
    bool? allowRandomDraw,
    List<String>? tags,
    List<String>? requiredEquipment,
  }) {
    return OrderItem(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      category: category ?? this.category,
      tier: tier ?? this.tier,
      durationType: durationType ?? this.durationType,
      actionDurationSeconds: actionDurationSeconds ?? this.actionDurationSeconds,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      cooldownHours: cooldownHours ?? this.cooldownHours,
      verificationType: verificationType ?? this.verificationType,
      rewardTokens: rewardTokens ?? this.rewardTokens,
      penaltyTokens: penaltyTokens ?? this.penaltyTokens,
      isMandatory: isMandatory ?? this.isMandatory,
      allowRandomDraw: allowRandomDraw ?? this.allowRandomDraw,
      tags: tags ?? List.from(this.tags),
      requiredEquipment: requiredEquipment ?? List.from(this.requiredEquipment),
    );
  }
}
