import 'dart:math';

class DisciplineLogEntry {
  final String id;
  final String orderTitle;
  final String category;
  final int tier;
  final int tokenDelta;
  final bool isSuccess;
  final String reason;
  final DateTime timestamp;

  DisciplineLogEntry({
    required this.id,
    required this.orderTitle,
    required this.category,
    required this.tier,
    required this.tokenDelta,
    required this.isSuccess,
    required this.reason,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'orderTitle': orderTitle,
      'category': category,
      'tier': tier,
      'tokenDelta': tokenDelta,
      'isSuccess': isSuccess,
      'reason': reason,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  factory DisciplineLogEntry.fromJson(Map<String, dynamic> json) {
    return DisciplineLogEntry(
      id: json['id'] as String? ?? '',
      orderTitle: json['orderTitle'] as String? ?? '',
      category: json['category'] as String? ?? 'General',
      tier: (json['tier'] as num?)?.toInt() ?? 1,
      tokenDelta: (json['tokenDelta'] as num?)?.toInt() ?? 0,
      isSuccess: json['isSuccess'] as bool? ?? true,
      reason: json['reason'] as String? ?? '',
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String)
          : DateTime.now(),
    );
  }
}

class UserStats {
  final int tokens;
  final int currentStreakDays;
  final int bestStreakDays;
  final int totalCompleted;
  final int totalFailed;
  final DateTime? lastActiveDate;
  final List<DisciplineLogEntry> history;

  UserStats({
    this.tokens = 50,
    this.currentStreakDays = 0,
    this.bestStreakDays = 0,
    this.totalCompleted = 0,
    this.totalFailed = 0,
    this.lastActiveDate,
    List<DisciplineLogEntry>? history,
  }) : history = history ?? [];

  double get complianceRate {
    final total = totalCompleted + totalFailed;
    if (total == 0) return 100.0;
    return (totalCompleted / total) * 100.0;
  }

  int get disciplineScore {
    // Score based on compliance, streak, and volume
    final base = (complianceRate * 0.6).round();
    final streakBonus = min(currentStreakDays * 2, 20);
    final volumeBonus = min(totalCompleted, 20);
    return min(100, base + streakBonus + volumeBonus);
  }

  Map<String, dynamic> toJson() {
    return {
      'tokens': tokens,
      'currentStreakDays': currentStreakDays,
      'bestStreakDays': bestStreakDays,
      'totalCompleted': totalCompleted,
      'totalFailed': totalFailed,
      'lastActiveDate': lastActiveDate?.toIso8601String(),
      'history': history.map((e) => e.toJson()).toList(),
    };
  }

  factory UserStats.fromJson(Map<String, dynamic> json) {
    return UserStats(
      tokens: (json['tokens'] as num?)?.toInt() ?? 50,
      currentStreakDays: (json['currentStreakDays'] as num?)?.toInt() ?? 0,
      bestStreakDays: (json['bestStreakDays'] as num?)?.toInt() ?? 0,
      totalCompleted: (json['totalCompleted'] as num?)?.toInt() ?? 0,
      totalFailed: (json['totalFailed'] as num?)?.toInt() ?? 0,
      lastActiveDate: json['lastActiveDate'] != null
          ? DateTime.parse(json['lastActiveDate'] as String)
          : null,
      history: (json['history'] as List<dynamic>?)
              ?.map((e) => DisciplineLogEntry.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  UserStats copyWith({
    int? tokens,
    int? currentStreakDays,
    int? bestStreakDays,
    int? totalCompleted,
    int? totalFailed,
    DateTime? lastActiveDate,
    List<DisciplineLogEntry>? history,
  }) {
    return UserStats(
      tokens: tokens ?? this.tokens,
      currentStreakDays: currentStreakDays ?? this.currentStreakDays,
      bestStreakDays: bestStreakDays ?? this.bestStreakDays,
      totalCompleted: totalCompleted ?? this.totalCompleted,
      totalFailed: totalFailed ?? this.totalFailed,
      lastActiveDate: lastActiveDate ?? this.lastActiveDate,
      history: history ?? List.from(this.history),
    );
  }
}
