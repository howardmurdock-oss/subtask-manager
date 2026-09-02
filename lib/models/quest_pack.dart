import 'package:uuid/uuid.dart';
import 'quest_item.dart';

/// Represents a collection/pack of Quest directive playlists that can be
/// crafted, exported, imported, and shared between partners.
class QuestPack {
  final String id;
  final String title;
  final String description;
  final String author;
  final String version;
  final DateTime createdAt;
  final bool isEnabled;
  final List<String> tags;
  final List<Quest> quests;

  QuestPack({
    String? id,
    required this.title,
    this.description = '',
    this.author = 'Anonymous',
    this.version = '1.0.0',
    DateTime? createdAt,
    this.isEnabled = true,
    List<String>? tags,
    List<Quest>? quests,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now(),
        tags = tags ?? [],
        quests = quests ?? [];

  /// Create a QuestPack containing a single Quest
  factory QuestPack.fromSingleQuest(Quest quest, {String? author}) {
    return QuestPack(
      title: quest.title,
      description: quest.description,
      author: author ?? quest.createdBy ?? 'Anonymous',
      tags: [quest.category, if (quest.isPreset) 'Preset'],
      quests: [quest],
    );
  }

  int get totalStepsCount {
    int sum = 0;
    for (final q in quests) {
      sum += q.steps.length;
    }
    return sum;
  }

  int get totalPotentialTokens {
    int sum = 0;
    for (final q in quests) {
      sum += q.totalPotentialTokens;
    }
    return sum;
  }

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
      'quests': quests.map((q) => q.toJson()).toList(),
    };
  }

  factory QuestPack.fromJson(Map<String, dynamic> json) {
    final rawQuests = json['quests'] as List<dynamic>? ?? [];
    return QuestPack(
      id: json['id'] as String?,
      title: json['title'] as String? ?? 'Untitled Quest Pack',
      description: json['description'] as String? ?? '',
      author: json['author'] as String? ?? 'Anonymous',
      version: json['version'] as String? ?? '1.0.0',
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now()
          : DateTime.now(),
      isEnabled: json['isEnabled'] as bool? ?? true,
      tags: (json['tags'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [],
      quests: rawQuests
          .map((q) => Quest.fromJson(Map<String, dynamic>.from(q as Map)))
          .toList(),
    );
  }

  QuestPack copyWith({
    String? id,
    String? title,
    String? description,
    String? author,
    String? version,
    DateTime? createdAt,
    bool? isEnabled,
    List<String>? tags,
    List<Quest>? quests,
  }) {
    return QuestPack(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      author: author ?? this.author,
      version: version ?? this.version,
      createdAt: createdAt ?? this.createdAt,
      isEnabled: isEnabled ?? this.isEnabled,
      tags: tags ?? List.from(this.tags),
      quests: quests ?? List.from(this.quests),
    );
  }
}
