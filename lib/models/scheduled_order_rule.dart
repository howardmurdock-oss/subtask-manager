import 'dart:math';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'order_item.dart';

enum ScheduleTargetType {
  directorDispatch,
  playerSelfDraw,
}

enum ScheduleTimingMode {
  specificTime,
  randomWindow,
}

enum RepeatFrequency {
  once,
  hourly,
  daily,
  weekly,
}

extension RepeatFrequencyExt on RepeatFrequency {
  String get displayName {
    switch (this) {
      case RepeatFrequency.once:
        return 'One-Time (No Repeat)';
      case RepeatFrequency.hourly:
        return 'Every Hour';
      case RepeatFrequency.daily:
        return 'Every Day';
      case RepeatFrequency.weekly:
        return 'Every Week';
    }
  }
}

class ScheduledOrderRule {
  final String id;
  final String title;
  final ScheduleTargetType targetType;
  final ScheduleTimingMode timingMode;
  final RepeatFrequency frequency;

  /// Used for specificTime mode (exact date/time for first trigger)
  final DateTime? specificScheduledTime;

  /// Used for randomWindow mode (start and end times of day)
  final int? windowStartHour;
  final int? windowStartMinute;
  final int? windowEndHour;
  final int? windowEndMinute;

  /// The next exact timestamp when this rule should execute
  final DateTime nextTriggerTime;

  /// For Director: whether to dispatch a specific order or a random order
  final bool isSpecificOrder;
  final OrderItem? specificOrder;

  /// Filters for random order draws (both Director and Player)
  final String? categoryFilter;
  final int minTier;
  final int maxTier;

  /// For Director: partner to receive the dispatch
  final String? targetPartnerId;
  final String? targetPartnerCode;
  final String? targetPartnerName;

  final bool isEnabled;
  final DateTime createdAt;
  final DateTime? lastTriggeredAt;

  ScheduledOrderRule({
    String? id,
    required this.title,
    required this.targetType,
    this.timingMode = ScheduleTimingMode.specificTime,
    this.frequency = RepeatFrequency.once,
    this.specificScheduledTime,
    this.windowStartHour,
    this.windowStartMinute,
    this.windowEndHour,
    this.windowEndMinute,
    DateTime? nextTriggerTime,
    this.isSpecificOrder = false,
    this.specificOrder,
    this.categoryFilter,
    this.minTier = 1,
    this.maxTier = 5,
    this.targetPartnerId,
    this.targetPartnerCode,
    this.targetPartnerName,
    this.isEnabled = true,
    DateTime? createdAt,
    this.lastTriggeredAt,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now(),
        nextTriggerTime = nextTriggerTime ??
            computeInitialTrigger(
              timingMode: timingMode,
              specificScheduledTime: specificScheduledTime,
              windowStartHour: windowStartHour,
              windowStartMinute: windowStartMinute,
              windowEndHour: windowEndHour,
              windowEndMinute: windowEndMinute,
            );

  static DateTime computeInitialTrigger({
    required ScheduleTimingMode timingMode,
    DateTime? specificScheduledTime,
    int? windowStartHour,
    int? windowStartMinute,
    int? windowEndHour,
    int? windowEndMinute,
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();

    if (timingMode == ScheduleTimingMode.specificTime) {
      if (specificScheduledTime != null) {
        if (specificScheduledTime.isAfter(current)) {
          return specificScheduledTime;
        }
        // If time is in the past for today, schedule for next occurrence based on time of day
        var next = DateTime(
          current.year,
          current.month,
          current.day,
          specificScheduledTime.hour,
          specificScheduledTime.minute,
          specificScheduledTime.second,
        );
        if (next.isBefore(current) || next.isAtSameMomentAs(current)) {
          next = next.add(const Duration(days: 1));
        }
        return next;
      }
      return current.add(const Duration(hours: 1));
    }

    // Random Window Mode
    final startH = windowStartHour ?? 15;
    final startM = windowStartMinute ?? 0;
    final endH = windowEndHour ?? 21;
    final endM = windowEndMinute ?? 0;

    return computeRandomWindowTrigger(startH, startM, endH, endM, fromTime: current);
  }

  static DateTime computeRandomWindowTrigger(
    int startHour,
    int startMinute,
    int endHour,
    int endMinute, {
    DateTime? fromTime,
  }) {
    final now = fromTime ?? DateTime.now();
    var windowStart = DateTime(now.year, now.month, now.day, startHour, startMinute);
    var windowEnd = DateTime(now.year, now.month, now.day, endHour, endMinute);

    // If windowEnd <= windowStart, assume it spans overnight
    if (windowEnd.isBefore(windowStart) || windowEnd.isAtSameMomentAs(windowStart)) {
      windowEnd = windowEnd.add(const Duration(days: 1));
    }

    // If window has already passed for today, move to tomorrow
    if (now.isAfter(windowEnd)) {
      windowStart = windowStart.add(const Duration(days: 1));
      windowEnd = windowEnd.add(const Duration(days: 1));
    }

    // Determine viable range: if now is within the window, pick between now and windowEnd
    final effectiveStart = now.isAfter(windowStart) ? now : windowStart;
    final totalSpanSeconds = windowEnd.difference(effectiveStart).inSeconds;

    if (totalSpanSeconds <= 60) {
      return windowEnd;
    }

    final rand = Random();
    final randomOffset = rand.nextInt(totalSpanSeconds);
    return effectiveStart.add(Duration(seconds: randomOffset));
  }

  /// Calculates the subsequent trigger time after a trigger fires
  DateTime? computeNextRecurrence([DateTime? triggeredAt]) {
    final base = triggeredAt ?? DateTime.now();

    switch (frequency) {
      case RepeatFrequency.once:
        return null; // One-time, should deactivate

      case RepeatFrequency.hourly:
        return base.add(const Duration(hours: 1));

      case RepeatFrequency.daily:
        if (timingMode == ScheduleTimingMode.randomWindow) {
          final nextDay = base.add(const Duration(days: 1));
          return computeRandomWindowTrigger(
            windowStartHour ?? 15,
            windowStartMinute ?? 0,
            windowEndHour ?? 21,
            windowEndMinute ?? 0,
            fromTime: DateTime(nextDay.year, nextDay.month, nextDay.day, 0, 0),
          );
        }
        if (specificScheduledTime != null) {
          return DateTime(
            base.year,
            base.month,
            base.day + 1,
            specificScheduledTime!.hour,
            specificScheduledTime!.minute,
          );
        }
        return base.add(const Duration(days: 1));

      case RepeatFrequency.weekly:
        if (timingMode == ScheduleTimingMode.randomWindow) {
          final nextWeek = base.add(const Duration(days: 7));
          return computeRandomWindowTrigger(
            windowStartHour ?? 15,
            windowStartMinute ?? 0,
            windowEndHour ?? 21,
            windowEndMinute ?? 0,
            fromTime: DateTime(nextWeek.year, nextWeek.month, nextWeek.day, 0, 0),
          );
        }
        if (specificScheduledTime != null) {
          return DateTime(
            base.year,
            base.month,
            base.day + 7,
            specificScheduledTime!.hour,
            specificScheduledTime!.minute,
          );
        }
        return base.add(const Duration(days: 7));
    }
  }

  String get formattedTiming {
    if (timingMode == ScheduleTimingMode.specificTime) {
      if (specificScheduledTime != null) {
        final timeStr = _formatTimeOfDay(TimeOfDay.fromDateTime(specificScheduledTime!));
        if (frequency == RepeatFrequency.once) {
          return '${specificScheduledTime!.month}/${specificScheduledTime!.day} at $timeStr';
        }
        return timeStr;
      }
      return 'Scheduled Time';
    }

    final startStr = _formatHourMinute(windowStartHour ?? 15, windowStartMinute ?? 0);
    final endStr = _formatHourMinute(windowEndHour ?? 21, windowEndMinute ?? 0);
    return 'Random Window ($startStr – $endStr)';
  }

  static String _formatHourMinute(int h, int m) {
    final period = h >= 12 ? 'PM' : 'AM';
    final formattedH = h == 0 ? 12 : (h > 12 ? h - 12 : h);
    final formattedM = m.toString().padLeft(2, '0');
    return '$formattedH:$formattedM $period';
  }

  static String _formatTimeOfDay(TimeOfDay tod) {
    return _formatHourMinute(tod.hour, tod.minute);
  }

  String get formattedTarget {
    if (targetType == ScheduleTargetType.directorDispatch) {
      final name = targetPartnerName ?? targetPartnerCode ?? 'Submissive';
      if (isSpecificOrder && specificOrder != null) {
        return 'Dispatch "${specificOrder!.title}" to $name';
      }
      final cat = categoryFilter != null ? '$categoryFilter ' : '';
      return 'Dispatch Random ${cat}Tier $minTier–$maxTier to $name';
    } else {
      final cat = categoryFilter != null ? '$categoryFilter ' : '';
      return 'Self-Draw Random ${cat}Tier $minTier–$maxTier';
    }
  }

  ScheduledOrderRule copyWith({
    String? id,
    String? title,
    ScheduleTargetType? targetType,
    ScheduleTimingMode? timingMode,
    RepeatFrequency? frequency,
    DateTime? specificScheduledTime,
    int? windowStartHour,
    int? windowStartMinute,
    int? windowEndHour,
    int? windowEndMinute,
    DateTime? nextTriggerTime,
    bool? isSpecificOrder,
    OrderItem? specificOrder,
    String? categoryFilter,
    int? minTier,
    int? maxTier,
    String? targetPartnerId,
    String? targetPartnerCode,
    String? targetPartnerName,
    bool? isEnabled,
    DateTime? createdAt,
    DateTime? lastTriggeredAt,
  }) {
    return ScheduledOrderRule(
      id: id ?? this.id,
      title: title ?? this.title,
      targetType: targetType ?? this.targetType,
      timingMode: timingMode ?? this.timingMode,
      frequency: frequency ?? this.frequency,
      specificScheduledTime: specificScheduledTime ?? this.specificScheduledTime,
      windowStartHour: windowStartHour ?? this.windowStartHour,
      windowStartMinute: windowStartMinute ?? this.windowStartMinute,
      windowEndHour: windowEndHour ?? this.windowEndHour,
      windowEndMinute: windowEndMinute ?? this.windowEndMinute,
      nextTriggerTime: nextTriggerTime ?? this.nextTriggerTime,
      isSpecificOrder: isSpecificOrder ?? this.isSpecificOrder,
      specificOrder: specificOrder ?? this.specificOrder,
      categoryFilter: categoryFilter ?? this.categoryFilter,
      minTier: minTier ?? this.minTier,
      maxTier: maxTier ?? this.maxTier,
      targetPartnerId: targetPartnerId ?? this.targetPartnerId,
      targetPartnerCode: targetPartnerCode ?? this.targetPartnerCode,
      targetPartnerName: targetPartnerName ?? this.targetPartnerName,
      isEnabled: isEnabled ?? this.isEnabled,
      createdAt: createdAt ?? this.createdAt,
      lastTriggeredAt: lastTriggeredAt ?? this.lastTriggeredAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'targetType': targetType.name,
        'timingMode': timingMode.name,
        'frequency': frequency.name,
        'specificScheduledTime': specificScheduledTime?.toIso8601String(),
        'windowStartHour': windowStartHour,
        'windowStartMinute': windowStartMinute,
        'windowEndHour': windowEndHour,
        'windowEndMinute': windowEndMinute,
        'nextTriggerTime': nextTriggerTime.toIso8601String(),
        'isSpecificOrder': isSpecificOrder,
        'specificOrder': specificOrder?.toJson(),
        'categoryFilter': categoryFilter,
        'minTier': minTier,
        'maxTier': maxTier,
        'targetPartnerId': targetPartnerId,
        'targetPartnerCode': targetPartnerCode,
        'targetPartnerName': targetPartnerName,
        'isEnabled': isEnabled,
        'createdAt': createdAt.toIso8601String(),
        'lastTriggeredAt': lastTriggeredAt?.toIso8601String(),
      };

  factory ScheduledOrderRule.fromJson(Map<String, dynamic> json) {
    return ScheduledOrderRule(
      id: json['id'] as String?,
      title: json['title'] as String? ?? 'Scheduled Protocol',
      targetType: ScheduleTargetType.values.firstWhere(
        (e) => e.name == json['targetType'],
        orElse: () => ScheduleTargetType.playerSelfDraw,
      ),
      timingMode: ScheduleTimingMode.values.firstWhere(
        (e) => e.name == json['timingMode'],
        orElse: () => ScheduleTimingMode.specificTime,
      ),
      frequency: RepeatFrequency.values.firstWhere(
        (e) => e.name == json['frequency'],
        orElse: () => RepeatFrequency.once,
      ),
      specificScheduledTime: json['specificScheduledTime'] != null
          ? DateTime.tryParse(json['specificScheduledTime'] as String)
          : null,
      windowStartHour: json['windowStartHour'] as int?,
      windowStartMinute: json['windowStartMinute'] as int?,
      windowEndHour: json['windowEndHour'] as int?,
      windowEndMinute: json['windowEndMinute'] as int?,
      nextTriggerTime: json['nextTriggerTime'] != null
          ? DateTime.tryParse(json['nextTriggerTime'] as String) ?? DateTime.now()
          : DateTime.now(),
      isSpecificOrder: json['isSpecificOrder'] as bool? ?? false,
      specificOrder: json['specificOrder'] != null
          ? OrderItem.fromJson(Map<String, dynamic>.from(json['specificOrder'] as Map))
          : null,
      categoryFilter: json['categoryFilter'] as String?,
      minTier: (json['minTier'] as num?)?.toInt() ?? 1,
      maxTier: (json['maxTier'] as num?)?.toInt() ?? 5,
      targetPartnerId: json['targetPartnerId'] as String?,
      targetPartnerCode: json['targetPartnerCode'] as String?,
      targetPartnerName: json['targetPartnerName'] as String?,
      isEnabled: json['isEnabled'] as bool? ?? true,
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now()
          : DateTime.now(),
      lastTriggeredAt: json['lastTriggeredAt'] != null
          ? DateTime.tryParse(json['lastTriggeredAt'] as String)
          : null,
    );
  }
}
