import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/quest_item.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/quest_service.dart';
import 'package:orders_app/services/sync_service.dart';

/// A quest with no steps cannot be completed: completion only happens on
/// finishing the last step, and there is no step to finish. One dispatched by
/// mistake sat on both dashboards for over a week reading "Step 1 of 0", with
/// nothing in the app able to shift it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Quest quest({required bool withSteps}) => Quest(
        id: 'quest_1',
        title: 'Do the Funk',
        description: '',
        steps: withSteps
            ? [QuestStep(id: 'step_1', orderIndex: 0, title: 'Get down', description: 'Funk it up')]
            : const [],
      );

  ActiveQuest active(Quest q) => ActiveQuest(
        id: 'active_1',
        quest: q,
        assignedByPartnerName: 'Beans',
        assignedByPartnerCode: 'GMJ7-UCVY',
      );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a quest with no steps is not runnable', () {
    expect(QuestService.isRunnable(quest(withSteps: false)), isFalse);
    expect(QuestService.isRunnable(quest(withSteps: true)), isTrue);
  });

  test('it is never dispatched', () async {
    final engine = OrderEngine();
    await engine.init();
    final partners = PartnerService();
    await partners.init();
    final sync = SyncService(engine, partnerService: partners);
    await sync.init(deferNetwork: true);
    sync.debugSentToCodes.clear();

    expect(sync.dispatchQuestToPlayer(quest(withSteps: false)), isFalse);
    expect(sync.debugSentToCodes, isEmpty);
  });

  test('the player refuses to start one', () async {
    final quests = QuestService();
    await quests.loadFromStorage();

    quests.startQuest(quest(withSteps: false), assignerName: 'Beans');
    expect(quests.activeQuest, isNull);

    quests.startQuest(quest(withSteps: true), assignerName: 'Beans');
    expect(quests.activeQuest, isNotNull);
  });

  test('one already stuck on a player is released on load', () async {
    SharedPreferences.setMockInitialValues({
      'player_active_quest_v1': jsonEncode(active(quest(withSteps: false)).toJson()),
    });

    final quests = QuestService();
    await quests.loadFromStorage();

    expect(quests.activeQuest, isNull, reason: 'it could never have been completed');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('player_active_quest_v1'), isNull);
  });

  test("one already stuck on a director's dashboard is released on load", () async {
    final stuck = active(quest(withSteps: false)).toJson();
    final runnable = ActiveQuest(id: 'active_2', quest: quest(withSteps: true)).toJson();
    SharedPreferences.setMockInitialValues({
      // The same dispatch is filed under several partner keys, which is why
      // clearing one of them was never enough.
      'director_remote_player_quests_v1': jsonEncode({
        'Z2ZQSA49': stuck,
        'GMJ7-UCVY': stuck,
        'contact-uuid': runnable,
      }),
    });

    final quests = QuestService();
    await quests.loadFromStorage();

    expect(quests.remotePlayerQuests.keys, ['contact-uuid']);
  });

  test('a director can clear a quest from every key it was filed under', () async {
    final runnable = ActiveQuest(id: 'active_2', quest: quest(withSteps: true)).toJson();
    SharedPreferences.setMockInitialValues({
      'director_remote_player_quests_v1': jsonEncode({
        'by-id': runnable,
        'by-code': runnable,
      }),
    });

    final quests = QuestService();
    await quests.loadFromStorage();
    expect(quests.remotePlayerQuests, hasLength(2));

    quests.clearRemotePlayerQuestById('active_2');

    expect(quests.remotePlayerQuests, isEmpty);
  });
}
