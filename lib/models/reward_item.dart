import 'package:uuid/uuid.dart';

class RewardItem {
  final String id;
  final String title;
  final String description;
  final int cost; // in tokens
  final String category; // e.g. Break, Privilege, Custom
  final bool requiresDirectorApproval;
  final bool isEnabled;

  RewardItem({
    String? id,
    required this.title,
    required this.description,
    required this.cost,
    this.category = 'Privilege',
    this.requiresDirectorApproval = false,
    this.isEnabled = true,
  }) : id = id ?? const Uuid().v4();

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'cost': cost,
      'category': category,
      'requiresDirectorApproval': requiresDirectorApproval,
      'isEnabled': isEnabled,
    };
  }

  factory RewardItem.fromJson(Map<String, dynamic> json) {
    return RewardItem(
      id: json['id'] as String?,
      title: json['title'] as String? ?? 'Untitled Reward',
      description: json['description'] as String? ?? '',
      cost: (json['cost'] as num?)?.toInt() ?? 50,
      category: json['category'] as String? ?? 'Privilege',
      requiresDirectorApproval: json['requiresDirectorApproval'] as bool? ?? false,
      isEnabled: json['isEnabled'] as bool? ?? true,
    );
  }

  RewardItem copyWith({
    String? id,
    String? title,
    String? description,
    int? cost,
    String? category,
    bool? requiresDirectorApproval,
    bool? isEnabled,
  }) {
    return RewardItem(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      cost: cost ?? this.cost,
      category: category ?? this.category,
      requiresDirectorApproval: requiresDirectorApproval ?? this.requiresDirectorApproval,
      isEnabled: isEnabled ?? this.isEnabled,
    );
  }
}
