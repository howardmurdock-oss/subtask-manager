import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'order_item.dart';

/// Represents a single discrete step within a larger chained Quest / Directive Playlist.
class QuestStep {
  final String id;
  final int orderIndex;
  final String title;
  final String description;
  final String? narrativeText;
  final DurationType durationType;
  final int durationMinutes;
  final int actionDurationSeconds;
  final int rewardTokens;
  final VerificationType verificationType;
  final List<String> requiredEquipment;
  final bool isHiddenUntilUnlocked;
  final bool isOptional;

  QuestStep({
    String? id,
    required this.orderIndex,
    required this.title,
    this.description = '',
    this.narrativeText,
    this.durationType = DurationType.instant,
    this.durationMinutes = 0,
    this.actionDurationSeconds = 0,
    this.rewardTokens = 5,
    this.verificationType = VerificationType.honorCheck,
    List<String>? requiredEquipment,
    this.isHiddenUntilUnlocked = false,
    this.isOptional = false,
  })  : id = id ?? const Uuid().v4(),
        requiredEquipment = requiredEquipment ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'orderIndex': orderIndex,
        'title': title,
        'description': description,
        'narrativeText': narrativeText,
        'durationType': durationType.name,
        'durationMinutes': durationMinutes,
        'actionDurationSeconds': actionDurationSeconds,
        'rewardTokens': rewardTokens,
        'verificationType': verificationType.name,
        'requiredEquipment': requiredEquipment,
        'isHiddenUntilUnlocked': isHiddenUntilUnlocked,
        'isOptional': isOptional,
      };

  factory QuestStep.fromJson(Map<String, dynamic> json) {
    return QuestStep(
      id: json['id'] as String?,
      orderIndex: (json['orderIndex'] as num?)?.toInt() ?? 0,
      title: json['title'] as String? ?? 'Untitled Step',
      description: json['description'] as String? ?? '',
      narrativeText: json['narrativeText'] as String?,
      durationType: DurationType.values.firstWhere(
        (e) => e.name == json['durationType'],
        orElse: () => DurationType.instant,
      ),
      durationMinutes: (json['durationMinutes'] as num?)?.toInt() ?? 0,
      actionDurationSeconds: (json['actionDurationSeconds'] as num?)?.toInt() ?? 0,
      rewardTokens: (json['rewardTokens'] as num?)?.toInt() ?? 5,
      verificationType: VerificationType.values.firstWhere(
        (e) => e.name == json['verificationType'],
        orElse: () => VerificationType.honorCheck,
      ),
      requiredEquipment: (json['requiredEquipment'] as List?)?.map((e) => e.toString()).toList() ?? [],
      isHiddenUntilUnlocked: json['isHiddenUntilUnlocked'] as bool? ?? false,
      isOptional: json['isOptional'] as bool? ?? false,
    );
  }

  QuestStep copyWith({
    String? id,
    int? orderIndex,
    String? title,
    String? description,
    String? narrativeText,
    DurationType? durationType,
    int? durationMinutes,
    int? actionDurationSeconds,
    int? rewardTokens,
    VerificationType? verificationType,
    List<String>? requiredEquipment,
    bool? isHiddenUntilUnlocked,
    bool? isOptional,
  }) {
    return QuestStep(
      id: id ?? this.id,
      orderIndex: orderIndex ?? this.orderIndex,
      title: title ?? this.title,
      description: description ?? this.description,
      narrativeText: narrativeText ?? this.narrativeText,
      durationType: durationType ?? this.durationType,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      actionDurationSeconds: actionDurationSeconds ?? this.actionDurationSeconds,
      rewardTokens: rewardTokens ?? this.rewardTokens,
      verificationType: verificationType ?? this.verificationType,
      requiredEquipment: requiredEquipment ?? List.from(this.requiredEquipment),
      isHiddenUntilUnlocked: isHiddenUntilUnlocked ?? this.isHiddenUntilUnlocked,
      isOptional: isOptional ?? this.isOptional,
    );
  }

  /// Convert this QuestStep into an OrderItem for single-directive compatibility
  OrderItem toOrderItem({String? questTitle}) {
    final prefix = questTitle != null && questTitle.isNotEmpty ? '[$questTitle] ' : '';
    return OrderItem(
      id: id,
      title: '$prefix$title',
      description: description,
      tier: 1,
      rewardTokens: rewardTokens,
      durationType: durationType,
      durationMinutes: durationMinutes,
      actionDurationSeconds: actionDurationSeconds,
      verificationType: verificationType,
      requiredEquipment: requiredEquipment,
      tags: ['Quest', if (questTitle != null) questTitle],
    );
  }
}

/// A complete multi-step Quest / Chained Directive Playlist definition.
class Quest {
  final String id;
  final String title;
  final String description;
  final String category;
  final int bonusTokensOnComplete;
  final List<QuestStep> steps;
  final List<String> requiredEquipment;
  final DateTime createdAt;
  final String? createdBy;
  final bool isPreset;

  Quest({
    String? id,
    required this.title,
    this.description = '',
    this.category = 'General Gauntlet',
    this.bonusTokensOnComplete = 25,
    List<QuestStep>? steps,
    List<String>? requiredEquipment,
    DateTime? createdAt,
    this.createdBy,
    this.isPreset = false,
  })  : id = id ?? const Uuid().v4(),
        steps = steps ?? [],
        requiredEquipment = requiredEquipment ?? _aggregateEquipment(steps ?? []),
        createdAt = createdAt ?? DateTime.now();

  static List<String> _aggregateEquipment(List<QuestStep> steps) {
    final set = <String>{};
    for (final s in steps) {
      set.addAll(s.requiredEquipment);
    }
    return set.toList();
  }

  int get totalPotentialTokens {
    int sum = bonusTokensOnComplete;
    for (final s in steps) {
      sum += s.rewardTokens;
    }
    return sum;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'category': category,
        'bonusTokensOnComplete': bonusTokensOnComplete,
        'steps': steps.map((s) => s.toJson()).toList(),
        'requiredEquipment': requiredEquipment,
        'createdAt': createdAt.toIso8601String(),
        'createdBy': createdBy,
        'isPreset': isPreset,
      };

  factory Quest.fromJson(Map<String, dynamic> json) {
    final rawSteps = json['steps'] as List? ?? [];
    final parsedSteps = rawSteps.map((s) => QuestStep.fromJson(Map<String, dynamic>.from(s as Map))).toList();

    return Quest(
      id: json['id'] as String?,
      title: json['title'] as String? ?? 'Untitled Quest',
      description: json['description'] as String? ?? '',
      category: json['category'] as String? ?? 'General Gauntlet',
      bonusTokensOnComplete: (json['bonusTokensOnComplete'] as num?)?.toInt() ?? 25,
      steps: parsedSteps,
      requiredEquipment: (json['requiredEquipment'] as List?)?.map((e) => e.toString()).toList() ?? _aggregateEquipment(parsedSteps),
      createdAt: json['createdAt'] != null ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now() : DateTime.now(),
      createdBy: json['createdBy'] as String?,
      isPreset: json['isPreset'] as bool? ?? false,
    );
  }

  Quest copyWith({
    String? id,
    String? title,
    String? description,
    String? category,
    int? bonusTokensOnComplete,
    List<QuestStep>? steps,
    List<String>? requiredEquipment,
    DateTime? createdAt,
    String? createdBy,
    bool? isPreset,
  }) {
    final newSteps = steps ?? List.from(this.steps);
    return Quest(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      category: category ?? this.category,
      bonusTokensOnComplete: bonusTokensOnComplete ?? this.bonusTokensOnComplete,
      steps: newSteps,
      requiredEquipment: requiredEquipment ?? _aggregateEquipment(newSteps),
      createdAt: createdAt ?? this.createdAt,
      createdBy: createdBy ?? this.createdBy,
      isPreset: isPreset ?? this.isPreset,
    );
  }
}

/// Tracks the status and proof submission for a specific step in an active Quest.
class ActiveQuestStepProgress {
  final String stepId;
  final bool isCompleted;
  final DateTime? completedAt;
  final String? proofText;
  final String? proofImagePath;
  final int tokensAwarded;

  ActiveQuestStepProgress({
    required this.stepId,
    this.isCompleted = false,
    this.completedAt,
    this.proofText,
    this.proofImagePath,
    this.tokensAwarded = 0,
  });

  Map<String, dynamic> toJson() => {
        'stepId': stepId,
        'isCompleted': isCompleted,
        'completedAt': completedAt?.toIso8601String(),
        'proofText': proofText,
        'proofImagePath': proofImagePath,
        'tokensAwarded': tokensAwarded,
      };

  factory ActiveQuestStepProgress.fromJson(Map<String, dynamic> json) {
    return ActiveQuestStepProgress(
      stepId: json['stepId'] as String? ?? '',
      isCompleted: json['isCompleted'] as bool? ?? false,
      completedAt: json['completedAt'] != null ? DateTime.tryParse(json['completedAt'] as String) : null,
      proofText: json['proofText'] as String?,
      proofImagePath: json['proofImagePath'] as String?,
      tokensAwarded: (json['tokensAwarded'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Represents an ongoing or completed Quest instance in the Player's active journey.
class ActiveQuest {
  final String id;
  final Quest quest;
  int currentStepIndex;
  final DateTime startedAt;
  DateTime? completedAt;
  bool isCompleted;
  final String? assignedByPartnerName;
  final String? assignedByPartnerCode;
  final List<ActiveQuestStepProgress> stepProgress;

  ActiveQuest({
    String? id,
    required this.quest,
    this.currentStepIndex = 0,
    DateTime? startedAt,
    this.completedAt,
    this.isCompleted = false,
    this.assignedByPartnerName,
    this.assignedByPartnerCode,
    List<ActiveQuestStepProgress>? stepProgress,
  })  : id = id ?? const Uuid().v4(),
        startedAt = startedAt ?? DateTime.now(),
        stepProgress = stepProgress ??
            quest.steps
                .map((s) => ActiveQuestStepProgress(stepId: s.id))
                .toList();

  QuestStep? get currentStep {
    if (currentStepIndex >= 0 && currentStepIndex < quest.steps.length) {
      return quest.steps[currentStepIndex];
    }
    return null;
  }

  int get totalSteps => quest.steps.length;

  int get completedStepsCount =>
      stepProgress.where((p) => p.isCompleted).length;

  double get progressFraction =>
      totalSteps > 0 ? (completedStepsCount / totalSteps).clamp(0.0, 1.0) : 0.0;

  Map<String, dynamic> toJson() => {
        'id': id,
        'quest': quest.toJson(),
        'currentStepIndex': currentStepIndex,
        'startedAt': startedAt.toIso8601String(),
        'completedAt': completedAt?.toIso8601String(),
        'isCompleted': isCompleted,
        'assignedByPartnerName': assignedByPartnerName,
        'assignedByPartnerCode': assignedByPartnerCode,
        'stepProgress': stepProgress.map((p) => p.toJson()).toList(),
      };

  factory ActiveQuest.fromJson(Map<String, dynamic> json) {
    final parsedQuest = Quest.fromJson(Map<String, dynamic>.from(json['quest'] as Map));
    final rawProgress = json['stepProgress'] as List? ?? [];
    final parsedProgress = rawProgress
        .map((p) => ActiveQuestStepProgress.fromJson(Map<String, dynamic>.from(p as Map)))
        .toList();

    return ActiveQuest(
      id: json['id'] as String?,
      quest: parsedQuest,
      currentStepIndex: (json['currentStepIndex'] as num?)?.toInt() ?? 0,
      startedAt: json['startedAt'] != null ? DateTime.tryParse(json['startedAt'] as String) ?? DateTime.now() : DateTime.now(),
      completedAt: json['completedAt'] != null ? DateTime.tryParse(json['completedAt'] as String) : null,
      isCompleted: json['isCompleted'] as bool? ?? false,
      assignedByPartnerName: json['assignedByPartnerName'] as String?,
      assignedByPartnerCode: json['assignedByPartnerCode'] as String?,
      stepProgress: parsedProgress,
    );
  }
}
