import 'package:uuid/uuid.dart';
import 'reward_item.dart';

class RewardPack {
  final String id;
  final String title;
  final String description;
  final String author;
  final String version;
  final DateTime createdAt;
  final bool isEnabled;
  final List<String> tags;
  final List<RewardItem> rewards;

  RewardPack({
    String? id,
    required this.title,
    this.description = '',
    this.author = 'Anonymous',
    this.version = '1.0.0',
    DateTime? createdAt,
    this.isEnabled = true,
    List<String>? tags,
    List<RewardItem>? rewards,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now(),
        tags = tags ?? [],
        rewards = rewards ?? [];

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'author': author,
      'version': version,
      'createdAt': createdAt.toIso8601String(),
      'isEnabled': isEnabled,
      'tags': tags,
      'rewards': rewards.map((r) => r.toJson()).toList(),
    };
  }

  factory RewardPack.fromJson(Map<String, dynamic> json) {
    return RewardPack(
      id: json['id'] as String?,
      title: json['title'] as String? ?? 'Untitled Reward Pack',
      description: json['description'] as String? ?? '',
      author: json['author'] as String? ?? 'Anonymous',
      version: json['version'] as String? ?? '1.0.0',
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
      isEnabled: json['isEnabled'] as bool? ?? true,
      tags: (json['tags'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [],
      rewards: (json['rewards'] as List<dynamic>?)
              ?.map((e) => RewardItem.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  RewardPack copyWith({
    String? id,
    String? title,
    String? description,
    String? author,
    String? version,
    DateTime? createdAt,
    bool? isEnabled,
    List<String>? tags,
    List<RewardItem>? rewards,
  }) {
    return RewardPack(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      author: author ?? this.author,
      version: version ?? this.version,
      createdAt: createdAt ?? this.createdAt,
      isEnabled: isEnabled ?? this.isEnabled,
      tags: tags ?? List.from(this.tags),
      rewards: rewards ?? List.from(this.rewards),
    );
  }
}
