import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import '../models/quest_item.dart';
import '../models/quest_pack.dart';
import '../models/order_item.dart';
import '../models/user_stats.dart';
import '../models/sync_message.dart';
import '../core/security/encryption_helper.dart';
import 'order_engine.dart';
import 'sync_service.dart';

class QuestService extends ChangeNotifier {
  static const String appCurrentBuildVersion = '1.1.0';

  // Valid Patreon Unlock Code hashes (stored securely as SHA-256 digests)
  // Included default codes: 'PATREON-VIP', 'QUESTS-2026', 'DIRECTIVE-CHAIN', 'PATREON-SUPPORTER', 'QUEST'
  static final Set<String> _validCodeHashes = {
    _hashPasscode('PATREON-VIP'),
    _hashPasscode('QUESTS-2026'),
    _hashPasscode('DIRECTIVE-CHAIN'),
    _hashPasscode('PATREON-SUPPORTER'),
    _hashPasscode('QUEST'),
    _hashPasscode('VIP'),
    _hashPasscode('SCHEDULE'),
    _hashPasscode('SCHEDULE-VIP'),
    _hashPasscode('PATREON'),
  };

  static String _hashPasscode(String raw) {
    final clean = raw.trim().toUpperCase();
    final bytes = utf8.encode('patreon_quest_salt_v1_$clean');
    return sha256.convert(bytes).toString();
  }

  bool _isUnlocked = false;
  bool get isUnlocked => _isUnlocked;

  List<Quest> _customQuests = [];
  List<Quest> get customQuests => List.unmodifiable(_customQuests);

  List<Quest> _presetQuests = [];
  List<Quest> get presetQuests => List.unmodifiable(_presetQuests);

  List<QuestPack> _questPacks = [];
  List<QuestPack> get questPacks => List.unmodifiable(_questPacks);

  List<Quest> get allQuests {
    final Map<String, Quest> map = {};
    for (final p in _presetQuests) {
      map[p.id] = p;
    }
    for (final c in _customQuests) {
      map[c.id] = c;
    }
    return map.values.toList();
  }

  ActiveQuest? _activeQuest;
  ActiveQuest? get activeQuest => _activeQuest;

  final List<ActiveQuest> _completedQuestsHistory = [];
  List<ActiveQuest> get completedQuestsHistory => List.unmodifiable(_completedQuestsHistory);

  // Director monitoring: Map of partnerId/Code -> ActiveQuest progress
  final Map<String, ActiveQuest> _remotePlayerQuests = {};
  Map<String, ActiveQuest> get remotePlayerQuests => Map.unmodifiable(_remotePlayerQuests);

  QuestService() {
    _initPresets();
    _loadFromStorage();
  }

  Future<void> _loadFromStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // 1. Check Patreon Unlock status for this build version
      final unlockedVersion = prefs.getString('quests_unlocked_build_version');
      final generalUnlocked = prefs.getBool('patreon_vip_unlocked_v1') ?? false;
      _isUnlocked = generalUnlocked || unlockedVersion == appCurrentBuildVersion;

      // 2. Load custom Quests library
      final savedQuestsJson = prefs.getString('saved_custom_quests_v1');
      if (savedQuestsJson != null && savedQuestsJson.isNotEmpty) {
        final List list = jsonDecode(savedQuestsJson);
        _customQuests = list
            .map((q) => Quest.fromJson(Map<String, dynamic>.from(q as Map)))
            .toList();
      }

      // 3. Load Quest Packs library
      final savedPacksJson = prefs.getString('saved_quest_packs_v1');
      if (savedPacksJson != null && savedPacksJson.isNotEmpty) {
        final List list = jsonDecode(savedPacksJson);
        _questPacks = list
            .map((p) => QuestPack.fromJson(Map<String, dynamic>.from(p as Map)))
            .toList();
      }

      // 4. Load active quest
      final activeQuestJson = prefs.getString('player_active_quest_v1');
      if (activeQuestJson != null && activeQuestJson.isNotEmpty) {
        _activeQuest = ActiveQuest.fromJson(Map<String, dynamic>.from(jsonDecode(activeQuestJson) as Map));
      }

      // 5. Load completed quests history
      final historyJson = prefs.getString('player_completed_quests_v1');
      if (historyJson != null && historyJson.isNotEmpty) {
        final List list = jsonDecode(historyJson);
        _completedQuestsHistory.clear();
        _completedQuestsHistory.addAll(
          list.map((q) => ActiveQuest.fromJson(Map<String, dynamic>.from(q as Map))),
        );
      }

      // 6. Load remote player quests (Director monitoring)
      final remoteQuestsJson = prefs.getString('director_remote_player_quests_v1');
      if (remoteQuestsJson != null && remoteQuestsJson.isNotEmpty) {
        final Map<String, dynamic> decoded = jsonDecode(remoteQuestsJson);
        _remotePlayerQuests.clear();
        decoded.forEach((key, val) {
          try {
            _remotePlayerQuests[key] = ActiveQuest.fromJson(Map<String, dynamic>.from(val as Map));
          } catch (_) {}
        });
      }

      notifyListeners();
    } catch (e) {
      if (kDebugMode) print('Error loading QuestService storage: $e');
    }
  }

  Future<void> _saveToStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('patreon_vip_unlocked_v1', _isUnlocked);
      if (_isUnlocked) {
        await prefs.setString('quests_unlocked_build_version', appCurrentBuildVersion);
      } else {
        await prefs.remove('quests_unlocked_build_version');
      }

      final encodedQuests = jsonEncode(_customQuests.map((q) => q.toJson()).toList());
      await prefs.setString('saved_custom_quests_v1', encodedQuests);

      final encodedPacks = jsonEncode(_questPacks.map((p) => p.toJson()).toList());
      await prefs.setString('saved_quest_packs_v1', encodedPacks);

      if (_activeQuest != null) {
        await prefs.setString('player_active_quest_v1', jsonEncode(_activeQuest!.toJson()));
      } else {
        await prefs.remove('player_active_quest_v1');
      }

      final encodedHistory = jsonEncode(_completedQuestsHistory.map((q) => q.toJson()).toList());
      await prefs.setString('player_completed_quests_v1', encodedHistory);

      final encodedRemote = jsonEncode(_remotePlayerQuests.map((k, v) => MapEntry(k, v.toJson())));
      await prefs.setString('director_remote_player_quests_v1', encodedRemote);
    } catch (e) {
      if (kDebugMode) print('Error saving QuestService storage: $e');
    }
  }

  // ---- Patreon Code Validation ----

  bool unlockWithPasscode(String passcode) {
    final hash = _hashPasscode(passcode);
    if (_validCodeHashes.contains(hash)) {
      _isUnlocked = true;
      _saveToStorage();
      notifyListeners();
      return true;
    }
    return false;
  }

  void relock() {
    _isUnlocked = false;
    _saveToStorage();
    notifyListeners();
  }

  // ---- Presets ----

  void _initPresets() {
    _presetQuests = [
      Quest(
        id: 'preset-morning-gauntlet',
        title: 'Morning Discipline Protocol',
        description: 'A 3-stage morning awakening ritual focused on posture, mindfulness, and ready submission.',
        category: 'Morning Ritual',
        bonusTokensOnComplete: 20,
        isPreset: true,
        steps: [
          QuestStep(
            id: 'm-step-1',
            orderIndex: 1,
            title: 'Hydrate & Attention Stance',
            description: 'Drink a full glass of cold water and stand at perfect attention with shoulders back for 2 minutes.',
            durationType: DurationType.actionTimer,
            actionDurationSeconds: 120,
            rewardTokens: 5,
            narrativeText: 'Clearing the fog of sleep. Stand tall and ready for directives.',
          ),
          QuestStep(
            id: 'm-step-2',
            orderIndex: 2,
            title: 'Spine & Posture Conditioning',
            description: 'Hold a kneeling or seated spine-erect posture for 5 minutes without slouching or fidgeting.',
            durationType: DurationType.actionTimer,
            durationMinutes: 5,
            actionDurationSeconds: 300,
            rewardTokens: 8,
            narrativeText: 'Cultivating stillness and physical discipline.',
          ),
          QuestStep(
            id: 'm-step-3',
            orderIndex: 3,
            title: 'Daily Intent & Affirmation',
            description: 'Reflect on your commitment to compliance today. Submit a brief text check-in or honor confirmation.',
            durationType: DurationType.instant,
            rewardTokens: 7,
            verificationType: VerificationType.honorCheck,
            narrativeText: 'Protocol complete. You are calibrated for obedience.',
          ),
        ],
      ),
      Quest(
        id: 'preset-core-endurance',
        title: 'Core & Endurance Trial',
        description: 'A rigorous 4-step physical gauntlet testing muscular endurance, stillness, and grit.',
        category: 'Fitness Gauntlet',
        bonusTokensOnComplete: 30,
        isPreset: true,
        steps: [
          QuestStep(
            id: 'c-step-1',
            orderIndex: 1,
            title: 'Plank Hold Induction',
            description: 'Hold a standard forearm plank with a straight line from heels to head for 60 seconds.',
            durationType: DurationType.actionTimer,
            actionDurationSeconds: 60,
            rewardTokens: 8,
          ),
          QuestStep(
            id: 'c-step-2',
            orderIndex: 2,
            title: 'Wall-Sit Endurance',
            description: 'Back flat against the wall, thighs parallel to the ground. Hold for 90 seconds.',
            durationType: DurationType.actionTimer,
            actionDurationSeconds: 90,
            rewardTokens: 10,
            isHiddenUntilUnlocked: true,
          ),
          QuestStep(
            id: 'c-step-3',
            orderIndex: 3,
            title: 'Controlled Calisthenics',
            description: 'Perform 20 slow, deliberate pushups or squats with strict form.',
            durationType: DurationType.instant,
            rewardTokens: 10,
            isHiddenUntilUnlocked: true,
          ),
          QuestStep(
            id: 'c-step-4',
            orderIndex: 4,
            title: 'Post-Exertion Stillness',
            description: 'Assume kneeling posture. Regulate your breathing back to normal in complete silence for 3 minutes.',
            durationType: DurationType.actionTimer,
            durationMinutes: 3,
            actionDurationSeconds: 180,
            rewardTokens: 12,
            isHiddenUntilUnlocked: true,
          ),
        ],
      ),
      Quest(
        id: 'preset-evening-surrender',
        title: 'Evening Surrender Routine',
        description: 'A 3-step evening wind-down protocol ensuring order, tidiness, and compliance before rest.',
        category: 'Evening Protocol',
        bonusTokensOnComplete: 25,
        isPreset: true,
        steps: [
          QuestStep(
            id: 'e-step-1',
            orderIndex: 1,
            title: 'Quarters & Space Tidiness',
            description: 'Clear all clutter from your immediate workspace or bedroom. Leave everything clean and ordered.',
            durationType: DurationType.deadlineCountdown,
            durationMinutes: 10,
            rewardTokens: 8,
          ),
          QuestStep(
            id: 'e-step-2',
            orderIndex: 2,
            title: 'Equipment & Gear Maintenance',
            description: 'Inspect, clean, and neatly secure all active gear and disciplinary equipment.',
            durationType: DurationType.instant,
            rewardTokens: 8,
          ),
          QuestStep(
            id: 'e-step-3',
            orderIndex: 3,
            title: 'Evening Compliance Log',
            description: 'Acknowledge all accomplishments and directives completed today. Prepare for restful submission.',
            durationType: DurationType.instant,
            rewardTokens: 9,
            verificationType: VerificationType.honorCheck,
          ),
        ],
      ),
    ];
  }

  // ---- Quest Management (Director) ----

  Future<void> saveCustomQuest(Quest quest) async {
    final idx = _customQuests.indexWhere((q) => q.id == quest.id);
    if (idx >= 0) {
      _customQuests[idx] = quest;
    } else {
      _customQuests.add(quest);
    }
    await _saveToStorage();
    notifyListeners();
  }

  Future<void> deleteCustomQuest(String questId) async {
    _customQuests.removeWhere((q) => q.id == questId);
    await _saveToStorage();
    notifyListeners();
  }

  // ---- Quest Pack Management (Director) ----

  Future<void> saveQuestPack(QuestPack pack) async {
    final idx = _questPacks.indexWhere((p) => p.id == pack.id);
    if (idx >= 0) {
      _questPacks[idx] = pack;
    } else {
      _questPacks.add(pack);
    }

    // Also ensure all quests inside the pack are present in customQuests library
    for (final q in pack.quests) {
      if (!_customQuests.any((existing) => existing.id == q.id)) {
        _customQuests.add(q);
      }
    }

    await _saveToStorage();
    notifyListeners();
  }

  Future<void> deleteQuestPack(String packId) async {
    _questPacks.removeWhere((p) => p.id == packId);
    await _saveToStorage();
    notifyListeners();
  }

  Future<void> toggleQuestPackEnabled(String packId, bool isEnabled) async {
    final idx = _questPacks.indexWhere((p) => p.id == packId);
    if (idx >= 0) {
      _questPacks[idx] = _questPacks[idx].copyWith(isEnabled: isEnabled);
      await _saveToStorage();
      notifyListeners();
    }
  }

  /// Import a QuestPack from JSON string or password-encrypted string
  Future<QuestPack> importQuestPack(String rawData, [String? password]) async {
    String jsonString = rawData.trim();
    if (password != null && password.isNotEmpty) {
      jsonString = EncryptionHelper.decryptString(jsonString, password);
    } else if (jsonString.startsWith('ey') || !jsonString.startsWith('{')) {
      // Possible base64 encrypted payload without password or wrong password
      try {
        final decoded = utf8.decode(base64Decode(jsonString));
        if (decoded.startsWith('{')) jsonString = decoded;
      } catch (_) {}
    }

    final Map<String, dynamic> decoded = jsonDecode(jsonString);
    final pack = QuestPack.fromJson(decoded);

    await saveQuestPack(pack);
    return pack;
  }

  /// Import an individual Quest from JSON or encrypted payload
  Future<Quest> importQuestFromJson(String rawData, [String? password]) async {
    String jsonString = rawData.trim();
    if (password != null && password.isNotEmpty) {
      jsonString = EncryptionHelper.decryptString(jsonString, password);
    }

    final Map<String, dynamic> decoded = jsonDecode(jsonString);

    // Check if the payload is a QuestPack or a single Quest
    if (decoded.containsKey('quests') && decoded['quests'] is List) {
      final pack = QuestPack.fromJson(decoded);
      await saveQuestPack(pack);
      return pack.quests.isNotEmpty ? pack.quests.first : Quest(title: pack.title, description: pack.description);
    }

    final quest = Quest.fromJson(decoded);
    await saveCustomQuest(quest);
    return quest;
  }

  /// Export a QuestPack to JSON string or password-encrypted string
  String exportQuestPack(QuestPack pack, [String? password]) {
    final rawJson = jsonEncode(pack.toJson());
    if (password != null && password.trim().isNotEmpty) {
      return EncryptionHelper.encryptString(rawJson, password.trim());
    }
    return rawJson;
  }

  /// Export a single Quest as a standalone JSON or password-encrypted string
  String exportQuest(Quest quest, [String? password]) {
    final rawJson = jsonEncode(quest.toJson());
    if (password != null && password.trim().isNotEmpty) {
      return EncryptionHelper.encryptString(rawJson, password.trim());
    }
    return rawJson;
  }

  // ---- Active Quest Management (Player) ----

  void startQuest(Quest quest, {String? assignerName, String? assignerCode}) {
    _activeQuest = ActiveQuest(
      quest: quest,
      assignedByPartnerName: assignerName,
      assignedByPartnerCode: assignerCode,
    );
    _saveToStorage();
    notifyListeners();
  }

  void assignQuestFromDirector(Quest quest, {String? directorName, String? directorCode}) {
    _isUnlocked = true; // Auto-unlock assigned quest access on player device
    _saveToStorage();
    startQuest(quest, assignerName: directorName, assignerCode: directorCode);
  }

  Future<void> completeCurrentStep({
    String? proofText,
    String? proofImagePath,
    OrderEngine? engine,
    SyncService? sync,
  }) async {
    if (_activeQuest == null || _activeQuest!.isCompleted) return;

    final quest = _activeQuest!.quest;
    final currentIdx = _activeQuest!.currentStepIndex;
    if (currentIdx >= quest.steps.length) return;

    final currentStep = quest.steps[currentIdx];

    // 1. Record step progress
    _activeQuest!.stepProgress[currentIdx] = ActiveQuestStepProgress(
      stepId: currentStep.id,
      isCompleted: true,
      completedAt: DateTime.now(),
      proofText: proofText,
      proofImagePath: proofImagePath,
      tokensAwarded: currentStep.rewardTokens,
    );

    // 2. Award step tokens to OrderEngine
    if (engine != null && currentStep.rewardTokens > 0) {
      engine.adjustTokens(
        currentStep.rewardTokens,
        'Completed Quest Step ${currentIdx + 1}: "${currentStep.title}"',
      );
      engine.stats.history.insert(
        0,
        DisciplineLogEntry(
          id: const Uuid().v4(),
          orderTitle: '[Quest: ${quest.title}] Step ${currentIdx + 1}: ${currentStep.title}',
          category: quest.category,
          tier: 1,
          isSuccess: true,
          tokenDelta: currentStep.rewardTokens,
          reason: 'Quest step verified',
        ),
      );
      engine.notifyListeners();
    }

    // 3. Notify Director directly over relay topic if paired
    if (sync != null) {
      sync.notifyQuestStepCompleted(
        quest,
        currentStep,
        currentIdx,
        quest.steps.length,
        tokensAwarded: currentStep.rewardTokens,
      );
    }

    // 4. Advance to next step or finalize Quest
    if (currentIdx + 1 < quest.steps.length) {
      _activeQuest!.currentStepIndex = currentIdx + 1;
    } else {
      // Final step finished: Grand Quest Completion!
      _activeQuest!.isCompleted = true;
      _activeQuest!.completedAt = DateTime.now();

      if (engine != null && quest.bonusTokensOnComplete > 0) {
        engine.adjustTokens(
          quest.bonusTokensOnComplete,
          'Conquered Full Quest: "${quest.title}"',
        );
        engine.stats.history.insert(
          0,
          DisciplineLogEntry(
            id: const Uuid().v4(),
            orderTitle: '🏆 [QUEST CONQUERED] ${quest.title}',
            category: quest.category,
            tier: 3,
            isSuccess: true,
            tokenDelta: quest.bonusTokensOnComplete,
            reason: 'Full quest chain completed',
          ),
        );
        engine.notifyListeners();
      }

      _completedQuestsHistory.insert(0, _activeQuest!);

      if (sync != null) {
        sync.notifyQuestCompleted(
          quest,
          bonusTokens: quest.bonusTokensOnComplete,
        );
      }
    }

    await _saveToStorage();
    notifyListeners();
  }

  Future<void> abandonActiveQuest() async {
    _activeQuest = null;
    await _saveToStorage();
    notifyListeners();
  }

  // ---- Director Remote Telemetry Updates ----

  void recordDispatchedQuest(
    String partnerKey,
    Quest quest, {
    String? partnerName,
    String? partnerCode,
  }) {
    if (partnerKey.isEmpty) return;
    final active = ActiveQuest(
      quest: quest,
      assignedByPartnerName: partnerName,
      assignedByPartnerCode: partnerCode,
    );
    _remotePlayerQuests[partnerKey] = active;
    if (partnerCode != null && partnerCode.isNotEmpty) {
      _remotePlayerQuests[partnerCode] = active;
    }
    _saveToStorage();
    notifyListeners();
  }

  void updateRemotePlayerQuestProgress({
    required String senderId,
    required String questId,
    required String questTitle,
    required int stepIndex,
    required String stepTitle,
    required int totalSteps,
    bool isCompleted = false,
  }) {
    ActiveQuest? existing = _remotePlayerQuests[senderId];
    if (existing == null) {
      for (final entry in _remotePlayerQuests.entries) {
        if (entry.value.quest.id == questId || entry.value.assignedByPartnerCode == senderId) {
          existing = entry.value;
          break;
        }
      }
    }

    if (existing != null) {
      existing.currentStepIndex = stepIndex;
      existing.isCompleted = isCompleted;
      if (isCompleted) existing.completedAt = DateTime.now();
      if (stepIndex < existing.stepProgress.length) {
        existing.stepProgress[stepIndex] = ActiveQuestStepProgress(
          stepId: existing.stepProgress[stepIndex].stepId,
          isCompleted: true,
          completedAt: DateTime.now(),
        );
      }
    } else {
      final q = allQuests.firstWhere(
        (q) => q.id == questId,
        orElse: () => Quest(id: questId, title: questTitle),
      );
      final newActive = ActiveQuest(
        quest: q,
        currentStepIndex: stepIndex,
        isCompleted: isCompleted,
      );
      _remotePlayerQuests[senderId] = newActive;
    }

    _saveToStorage();
    notifyListeners();
  }

  void updateRemotePlayerQuestFromState(String senderId, ActiveQuest quest) {
    _remotePlayerQuests[senderId] = quest;
    if (quest.assignedByPartnerCode != null && quest.assignedByPartnerCode!.isNotEmpty) {
      _remotePlayerQuests[quest.assignedByPartnerCode!] = quest;
    }
    _saveToStorage();
    notifyListeners();
  }

  void markRemotePlayerQuestCompleted(String senderId, String questId) {
    final existing = _remotePlayerQuests[senderId];
    if (existing != null) {
      existing.isCompleted = true;
      existing.completedAt = DateTime.now();
    }
    _saveToStorage();
    notifyListeners();
  }

  void clearRemotePlayerQuest(String senderId) {
    _remotePlayerQuests.remove(senderId);
    _saveToStorage();
    notifyListeners();
  }
}
