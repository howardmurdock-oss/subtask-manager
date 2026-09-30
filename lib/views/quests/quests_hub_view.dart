import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/sync_service.dart';
import '../../services/quest_service.dart';
import '../home_screen.dart';
import 'quest_gate_view.dart';
import 'player_quest_view.dart';
import 'director_quest_view.dart';

class QuestsHubView extends StatelessWidget {
  final AppRole currentRole;

  const QuestsHubView({
    super.key,
    required this.currentRole,
  });

  @override
  Widget build(BuildContext context) {
    final questSvc = Provider.of<QuestService>(context);

    // If player has an active assigned quest, grant direct access to their assigned duties
    final hasActiveAssignedQuest = questSvc.activeQuest != null && !questSvc.activeQuest!.isCompleted;

    // A director without the code may still come in when a partner of theirs
    // supports on Patreon; the studio then only sends quests to supporters.
    SyncService? sync;
    try {
      sync = Provider.of<SyncService>(context);
    } catch (_) {}
    final sponsored = currentRole == AppRole.director && (sync?.supporterContacts().isNotEmpty ?? false);

    if (!questSvc.isUnlocked && !hasActiveAssignedQuest && !sponsored) {
      return const QuestGateView();
    }

    if (currentRole == AppRole.director) {
      return const DirectorQuestView();
    }

    return const PlayerQuestView();
  }
}
