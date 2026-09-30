import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/models/scheduled_order_rule.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/services/chat_service.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/patreon_sponsorship.dart';
import 'package:orders_app/services/quest_service.dart';
import 'package:orders_app/services/schedule_service.dart';
import 'package:orders_app/services/storage_service.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/views/home_screen.dart' show AppRole;
import 'package:orders_app/views/quests/director_quest_view.dart';
import 'package:orders_app/views/quests/quest_gate_view.dart';
import 'package:orders_app/views/quests/quests_hub_view.dart';
import 'package:orders_app/views/scheduling/schedule_order_dialog.dart';

/// A Patreon supporter's features extend to the directors who play with
/// them - for that player only - and a director's scheduled orders for them
/// pause while their support is not announced.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final supporter = PartnerContact(
    id: 'p-supporter',
    displayName: 'PC 1',
    pairingCode: 'SUP111',
    pairingSecret: 's',
    role: PartnerRole.submissive,
  );
  final other = PartnerContact(
    id: 'p-other',
    displayName: 'Someone Else',
    pairingCode: 'OTH222',
    pairingSecret: 's',
    role: PartnerRole.submissive,
  );

  String features(Map<String, List<String>> byCode) => jsonEncode(byCode);

  ScheduledOrderRule directorRule(PartnerContact target, {String id = 'r1'}) => ScheduledOrderRule(
        id: id,
        title: 'Evening check',
        targetType: ScheduleTargetType.directorDispatch,
        frequency: RepeatFrequency.once,
        nextTriggerTime: DateTime.now().subtract(const Duration(minutes: 1)),
        targetPartnerId: target.id,
        targetPartnerCode: target.pairingCode,
        targetPartnerName: target.displayName,
        specificOrder: OrderItem(id: 'o1', title: 'Check in', description: 'Now', durationType: DurationType.instant),
        isSpecificOrder: true,
      );

  group('which rules pause', () {
    test("a director's rule for a supporter fires; for anyone else, it pauses", () async {
      SharedPreferences.setMockInitialValues({
        PatreonSponsorship.partnerFeaturesKey: features({'SUP111': ['otherFeature', 'patreonSupporter']}),
      });
      final prefs = await SharedPreferences.getInstance();
      expect(PatreonSponsorship.isPaused(directorRule(supporter), prefs), isFalse);
      expect(PatreonSponsorship.isPaused(directorRule(other), prefs), isTrue);
    });

    test("a director's own code means nothing pauses", () async {
      SharedPreferences.setMockInitialValues({PatreonSponsorship.unlockKey: true});
      final prefs = await SharedPreferences.getInstance();
      expect(PatreonSponsorship.isPaused(directorRule(other), prefs), isFalse);
    });

    test('rules for "Myself" and player self-draws never pause', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final self = PartnerContact.self();
      expect(PatreonSponsorship.isPaused(directorRule(self), prefs), isFalse);
      final selfDraw = ScheduledOrderRule(
        id: 's1',
        title: 'Mine',
        targetType: ScheduleTargetType.playerSelfDraw,
        frequency: RepeatFrequency.once,
        nextTriggerTime: DateTime.now(),
      );
      expect(PatreonSponsorship.isPaused(selfDraw, prefs), isFalse);
    });
  });

  group('with a paired partner', () {
    late OrderEngine engine;
    late PartnerService partners;
    late SyncService sync;
    late QuestService quests;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      engine = OrderEngine(storage: StorageService());
      await engine.init();
      partners = PartnerService();
      await partners.init();
      await partners.addContact(supporter);
      await partners.addContact(other);
      await partners.setActivePartner(supporter.id);
      final chat = ChatService();
      await chat.init();
      quests = QuestService();
      sync = SyncService(engine, partnerService: partners);
      sync.attachServices(partners, chat, questService: quests);
    });

    Future<void> announce(PartnerContact from, List<String> list) => sync.handleIncomingSyncMessage(SyncMessage(
          type: SyncMessageType.featureHello,
          senderId: 'x-${from.id}',
          payload: {'senderCode': from.pairingCode, 'features': list},
        ));

    test('a copy with the code announces it supports; one without does not', () async {
      expect(await sync.currentFeatures(), isNot(contains(PatreonSponsorship.supporterFeature)));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(PatreonSponsorship.unlockKey, true);
      expect(await sync.currentFeatures(), contains(PatreonSponsorship.supporterFeature));
    });

    test('supporters are only those who announced it', () async {
      await announce(supporter, ['otherFeature', 'patreonSupporter']);
      await announce(other, ['otherFeature']);
      expect(sync.isSupporter(supporter), isTrue);
      expect(sync.isSupporter(other), isFalse);
      expect(sync.supporterContacts().map((c) => c.id), ['p-supporter']);
    });

    test('support that stops being announced ends it', () async {
      await announce(supporter, ['otherFeature', 'patreonSupporter']);
      await announce(supporter, ['otherFeature']);
      expect(sync.isSupporter(supporter), isFalse);
    });

    Future<ScheduleService> scheduleWith(ScheduledOrderRule rule) async {
      final schedule = ScheduleService();
      await schedule.init();
      schedule.attachDependencies(orderEngine: engine, syncService: sync, partnerService: partners);
      await schedule.addRule(rule);
      return schedule;
    }

    test("a sponsored director's scheduled order is sent while the player supports", () async {
      await announce(supporter, ['patreonSupporter']);
      final schedule = await scheduleWith(directorRule(supporter));

      await schedule.checkDueRules();

      expect(sync.remoteActiveOrders.map((o) => o.order.title), ['Check in']);
    });

    test('and is skipped, not queued, once their support is not announced', () async {
      await announce(supporter, ['otherFeature']);
      final schedule = await scheduleWith(directorRule(supporter));

      await schedule.checkDueRules();

      expect(sync.remoteActiveOrders, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(ScheduleService.pausedNotifiedKey), ['r1'], reason: 'the director is told once');
    });

    Future<void> pumpHub(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: engine),
          ChangeNotifierProvider.value(value: partners),
          ChangeNotifierProvider.value(value: sync),
          ChangeNotifierProvider.value(value: quests),
        ],
        child: const MaterialApp(home: Scaffold(body: QuestsHubView(currentRole: AppRole.director))),
      ));
      await tester.pump();
    }

    testWidgets('a director without the code is let into Quests by a supporter, and told whose', (tester) async {
      await announce(supporter, ['patreonSupporter']);
      await pumpHub(tester);

      expect(find.byType(DirectorQuestView), findsOneWidget);
      expect(find.textContaining("Unlocked by PC 1's Patreon support"), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });

    Future<ScheduleService> openScheduling(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final schedule = ScheduleService();
      await schedule.init();
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: engine),
          ChangeNotifierProvider.value(value: partners),
          ChangeNotifierProvider.value(value: sync),
          ChangeNotifierProvider.value(value: quests),
          ChangeNotifierProvider.value(value: schedule),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => ScheduleOrderDialog.show(context, isDirectorMode: true),
                child: const Text('schedule'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('schedule'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      return schedule;
    }

    testWidgets('scheduling opens for a supporter, offering only them', (tester) async {
      await announce(supporter, ['patreonSupporter']);
      final schedule = await openScheduling(tester);

      expect(find.text('Patreon Exclusive: Scheduled Orders'), findsNothing);
      expect(find.textContaining("Unlocked by PC 1's Patreon support"), findsOneWidget);
      expect(find.textContaining('Someone Else'), findsNothing);
      expect(find.textContaining('Myself'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      schedule.dispose();
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('with no supporter, scheduling shows the Patreon gate', (tester) async {
      final schedule = await openScheduling(tester);
      expect(find.text('Patreon Exclusive: Scheduled Orders'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      schedule.dispose();
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('with no supporter, the director sees the Patreon gate', (tester) async {
      await pumpHub(tester);

      expect(find.byType(QuestGateView), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  });
}
