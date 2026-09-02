import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/quest_item.dart';
import '../../models/order_item.dart';
import '../../services/quest_service.dart';
import '../../services/order_engine.dart';
import '../../services/sync_service.dart';
import '../../core/sound/sound_service.dart';

class PlayerQuestView extends StatefulWidget {
  const PlayerQuestView({super.key});

  @override
  State<PlayerQuestView> createState() => _PlayerQuestViewState();
}

class _PlayerQuestViewState extends State<PlayerQuestView> {
  Timer? _stepTimer;
  int _timerSecondsRemaining = 0;
  bool _isTimerRunning = false;
  final TextEditingController _proofNotesCtrl = TextEditingController();

  @override
  void dispose() {
    _stepTimer?.cancel();
    _proofNotesCtrl.dispose();
    super.dispose();
  }

  void _startStepTimer(int seconds) {
    _stepTimer?.cancel();
    setState(() {
      _timerSecondsRemaining = seconds;
      _isTimerRunning = true;
    });

    _stepTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        if (_timerSecondsRemaining > 1) {
          _timerSecondsRemaining--;
        } else {
          _timerSecondsRemaining = 0;
          _isTimerRunning = false;
          timer.cancel();
          try {
            SoundService.playAlarm();
          } catch (_) {}
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⏱️ Step timer completed! You can now verify and advance.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      });
    });
  }

  void _completeStep(ActiveQuest activeQuest, QuestStep currentStep) async {
    final questSvc = Provider.of<QuestService>(context, listen: false);
    final engine = Provider.of<OrderEngine>(context, listen: false);
    final sync = Provider.of<SyncService>(context, listen: false);

    final isLastStep = activeQuest.currentStepIndex + 1 >= activeQuest.quest.steps.length;

    await questSvc.completeCurrentStep(
      proofText: _proofNotesCtrl.text.trim().isNotEmpty ? _proofNotesCtrl.text.trim() : null,
      engine: engine,
      sync: sync,
    );

    _stepTimer?.cancel();
    _isTimerRunning = false;
    _proofNotesCtrl.clear();

    if (mounted) {
      if (isLastStep) {
        _showCompletionDialog(activeQuest.quest);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.greenAccent),
                const SizedBox(width: 10),
                Text('Step Complete! +${currentStep.rewardTokens} Tokens Claimed'),
              ],
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _showCompletionDialog(Quest quest) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(
            children: [
              Icon(Icons.emoji_events_rounded, color: Colors.amber, size: 30),
              SizedBox(width: 10),
              Text('Quest Conquered!'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'You have successfully completed all steps in "${quest.title}".',
                style: const TextStyle(fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.amber, width: 1.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.stars_rounded, color: Colors.amber, size: 24),
                    const SizedBox(width: 8),
                    Text(
                      '+${quest.bonusTokensOnComplete} BONUS TOKENS',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: Colors.amber,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
              ),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Awesome!'),
            ),
          ],
        );
      },
    );
  }

  void _promptAbandonQuest() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Abandon Active Quest?'),
        content: const Text(
          'Are you sure you want to cancel this quest? Progress on incomplete steps will be lost.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Keep Going'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            onPressed: () {
              Provider.of<QuestService>(context, listen: false).abandonActiveQuest();
              Navigator.pop(ctx);
            },
            child: const Text('Abandon'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final questSvc = Provider.of<QuestService>(context);
    final activeQuest = questSvc.activeQuest;
    final theme = Theme.of(context);

    if (activeQuest != null && !activeQuest.isCompleted) {
      return _buildActiveQuestView(activeQuest, theme);
    }

    return _buildQuestLibraryView(questSvc, theme);
  }

  Widget _buildActiveQuestView(ActiveQuest activeQuest, ThemeData theme) {
    final quest = activeQuest.quest;
    final currentStep = activeQuest.currentStep;
    final progress = activeQuest.progressFraction;
    final stepNum = activeQuest.currentStepIndex + 1;
    final totalSteps = activeQuest.totalSteps;

    return Scaffold(
      appBar: AppBar(
        title: Text(quest.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.close_rounded),
            tooltip: 'Abandon Quest',
            onPressed: _promptAbandonQuest,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Hero Progress Card
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          quest.category.toUpperCase(),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'Step $stepNum of $totalSteps',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 10,
                      backgroundColor: theme.colorScheme.surfaceVariant,
                      valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${(progress * 100).toInt()}% Completed',
                        style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.6)),
                      ),
                      Row(
                        children: [
                          const Icon(Icons.stars_rounded, size: 16, color: Colors.amber),
                          const SizedBox(width: 4),
                          Text(
                            '+${quest.bonusTokensOnComplete} Bonus Tokens',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.amber),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Active Step In-Progress Focus Card
          if (currentStep != null) ...[
            Text(
              'ACTIVE DIRECTIVE',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Card(
              elevation: 3,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: theme.colorScheme.primary, width: 1.5),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          backgroundColor: theme.colorScheme.primary,
                          foregroundColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
                          radius: 16,
                          child: Text('$stepNum', style: const TextStyle(fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                currentStep.title,
                                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                              ),
                              if (currentStep.narrativeText != null && currentStep.narrativeText!.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primary.withOpacity(0.08),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    '"${currentStep.narrativeText}"',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontStyle: FontStyle.italic,
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.greenAccent.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '+${currentStep.rewardTokens} Tokens',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.greenAccent[400],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      currentStep.description,
                      style: const TextStyle(fontSize: 14, height: 1.4),
                    ),

                    // Required Equipment
                    if (currentStep.requiredEquipment.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: currentStep.requiredEquipment.map((eq) => Chip(
                          visualDensity: VisualDensity.compact,
                          avatar: const Icon(Icons.shield_outlined, size: 14),
                          label: Text(eq, style: const TextStyle(fontSize: 11)),
                          backgroundColor: theme.colorScheme.surfaceVariant.withOpacity(0.5),
                        )).toList(),
                      ),
                    ],

                    // Action Timer Section
                    if (currentStep.durationType == DurationType.actionTimer ||
                        currentStep.durationType == DurationType.deadlineCountdown ||
                        currentStep.durationType == DurationType.actionWithDeadline) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceVariant.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.timer_outlined, color: theme.colorScheme.primary),
                                const SizedBox(width: 8),
                                Text(
                                  _timerSecondsRemaining > 0
                                      ? OrderItem.formatSecondsHuman(_timerSecondsRemaining)
                                      : OrderItem.formatSecondsHuman(
                                          currentStep.actionDurationSeconds > 0
                                              ? currentStep.actionDurationSeconds
                                              : (currentStep.durationMinutes > 0
                                                  ? currentStep.durationMinutes * 60
                                                  : 60),
                                        ),
                                  style: const TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            if (!_isTimerRunning && _timerSecondsRemaining == 0)
                              ElevatedButton.icon(
                                icon: const Icon(Icons.play_arrow_rounded),
                                label: const Text('Start Step Timer'),
                                onPressed: () {
                                  final totalSec = currentStep.actionDurationSeconds > 0
                                      ? currentStep.actionDurationSeconds
                                      : (currentStep.durationMinutes > 0
                                          ? currentStep.durationMinutes * 60
                                          : 60);
                                  _startStepTimer(totalSec);
                                },
                              )
                            else if (_isTimerRunning)
                              OutlinedButton.icon(
                                icon: const Icon(Icons.pause_rounded),
                                label: const Text('Pause Timer'),
                                onPressed: () {
                                  _stepTimer?.cancel();
                                  setState(() => _isTimerRunning = false);
                                },
                              ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 20),

                    // Step Completion Action Button
                    ElevatedButton.icon(
                      icon: const Icon(Icons.check_circle_rounded),
                      label: Text('Complete Step $stepNum (+${currentStep.rewardTokens} Tokens)'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: theme.colorScheme.brightness == Brightness.dark
                            ? Colors.black
                            : Colors.white,
                        minimumSize: const Size(double.infinity, 48),
                      ),
                      onPressed: () => _completeStep(activeQuest, currentStep),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),

          // Entire Quest Step Trail / Overview
          Text(
            'QUEST ROADMAP',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
              color: theme.colorScheme.onSurface.withOpacity(0.6),
            ),
          ),
          const SizedBox(height: 8),

          ...List.generate(quest.steps.length, (idx) {
            final s = quest.steps[idx];
            final isCompleted = idx < activeQuest.currentStepIndex;
            final isCurrent = idx == activeQuest.currentStepIndex;
            final isLocked = idx > activeQuest.currentStepIndex;
            final isHidden = isLocked && s.isHiddenUntilUnlocked;

            return Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              color: isCompleted
                  ? Colors.green.withOpacity(0.08)
                  : isCurrent
                      ? theme.colorScheme.primary.withOpacity(0.08)
                      : null,
              child: ListTile(
                leading: CircleAvatar(
                  radius: 14,
                  backgroundColor: isCompleted
                      ? Colors.green
                      : isCurrent
                          ? theme.colorScheme.primary
                          : theme.colorScheme.surfaceVariant,
                  foregroundColor: isCompleted || isCurrent ? Colors.white : theme.colorScheme.onSurface,
                  child: isCompleted
                      ? const Icon(Icons.check_rounded, size: 16)
                      : Text('${idx + 1}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ),
                title: Text(
                  isHidden ? '??? Locked Mystery Step' : s.title,
                  style: TextStyle(
                    fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                    color: isHidden ? theme.colorScheme.onSurface.withOpacity(0.5) : null,
                  ),
                ),
                subtitle: isHidden
                    ? const Text('Reveals upon reaching this step', style: TextStyle(fontSize: 11))
                    : Text(s.description, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                trailing: Text(
                  '+${s.rewardTokens} tk',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isCompleted ? Colors.green : theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildQuestLibraryView(QuestService questSvc, ThemeData theme) {
    final allQuests = questSvc.allQuests;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Quests & Directives Playlists'),
      ),
      body: allQuests.isEmpty
          ? const Center(child: Text('No quests available.'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: theme.colorScheme.primary.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.auto_stories_rounded, color: theme.colorScheme.primary, size: 36),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Select a Quest to Begin',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Progress through chained sequential directives to earn cumulative rewards.',
                              style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.7)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                Text(
                  'AVAILABLE QUESTS (${allQuests.length})',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 8),

                ...allQuests.map((q) => Card(
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                q.category.toUpperCase(),
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (q.isPreset)
                              const Chip(
                                visualDensity: VisualDensity.compact,
                                label: Text('PRESET', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold)),
                              ),
                            const Spacer(),
                            Row(
                              children: [
                                const Icon(Icons.stars_rounded, size: 16, color: Colors.amber),
                                const SizedBox(width: 4),
                                Text(
                                  '+${q.totalPotentialTokens} Total Tokens',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.amber),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          q.title,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          q.description,
                          style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withOpacity(0.7)),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Icon(Icons.format_list_numbered_rounded, size: 16, color: theme.colorScheme.onSurface.withOpacity(0.6)),
                            const SizedBox(width: 6),
                            Text(
                              '${q.steps.length} Steps',
                              style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.7)),
                            ),
                            const Spacer(),
                            ElevatedButton.icon(
                              icon: const Icon(Icons.play_arrow_rounded, size: 18),
                              label: const Text('Start Quest'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: theme.colorScheme.primary,
                                foregroundColor: theme.colorScheme.brightness == Brightness.dark ? Colors.black : Colors.white,
                              ),
                              onPressed: () {
                                questSvc.startQuest(q);
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                )),
              ],
            ),
    );
  }
}
