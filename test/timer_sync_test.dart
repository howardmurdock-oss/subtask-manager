import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/chastity_timer.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/models/sync_message.dart';
import 'package:orders_app/services/chastity_timer_service.dart';
import 'package:orders_app/services/chat_service.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/quest_service.dart';
import 'package:orders_app/services/storage_service.dart';
import 'package:orders_app/services/sync_service.dart';

/// What paired copies of the app tell each other about the chastity timer:
/// which features they have, the key to a timer, and that a timer changed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PartnerService partners;
  late SyncService sync;
  late ChastityTimerService timers;
  late List<Uri> fetched;

  final partner = PartnerContact(
    id: 'contact-1',
    displayName: 'Tessa',
    pairingCode: 'TES123',
    pairingSecret: 'secret-1',
    role: PartnerRole.dominant,
  );

  Map<String, dynamic> view(String id, String role) => {
        'id': id,
        'role': role,
        'manager': false,
        'status': 'running',
        'startAt': DateTime.now().millisecondsSinceEpoch,
        'endAt': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
        'config': {'baseSeconds': 3600},
        'history': [],
        'now': DateTime.now().millisecondsSinceEpoch,
      };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    fetched = [];
    ChastityTimerService.request = (method, url, {key, body}) async {
      fetched.add(url);
      return TimerApiResponse(200, view('timer-1', 'player'));
    };

    final engine = OrderEngine(storage: StorageService());
    await engine.init();
    partners = PartnerService();
    await partners.init();
    await partners.addContact(partner);
    final chat = ChatService();
    await chat.init();
    sync = SyncService(engine);
    sync.attachServices(partners, chat, questService: QuestService());
    timers = ChastityTimerService();
    await timers.load();
    sync.attachTimerService(timers);
  });

  SyncMessage from(String code, SyncMessageType type, Map<String, dynamic> payload) =>
      SyncMessage(type: type, senderId: 'their-device', payload: {'senderCode': code, ...payload});

  group('features', () {
    test('a partner that never says is taken not to have the timer', () {
      expect(sync.featuresOf(partner), isNull);
      expect(sync.partnerHas(partner, 'chastityTimer'), isFalse);
    });

    test("a partner's announced features are kept, across a restart", () async {
      await sync.handleIncomingSyncMessage(
          from('TES123', SyncMessageType.featureHello, {'features': ['chastityTimer']}));

      expect(sync.partnerHas(partner, 'chastityTimer'), isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(SyncService.partnerFeaturesKey), contains('chastityTimer'));
    });

    test('an announcement from someone not paired is ignored', () async {
      await sync.handleIncomingSyncMessage(
          from('STRANGER', SyncMessageType.featureHello, {'features': ['chastityTimer']}));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(SyncService.partnerFeaturesKey) ?? '', isNot(contains('STRANGER')));
    });
  });

  group('sharing a timer', () {
    test("a partner's key is added as a timer on this device", () async {
      await sync.handleIncomingSyncMessage(from('TES123', SyncMessageType.timerShare, {
        'timerId': 'timer-1',
        'key': 'PLAYER-KEY',
        'role': 'player',
      }));

      final record = timers.recordOf('timer-1');
      expect(record, isNotNull);
      expect(record!.role, TimerRole.player);
      expect(record.key, 'PLAYER-KEY');
      expect(record.partnerName, 'Tessa');
      expect(fetched, isNotEmpty, reason: 'it is fetched straight away');
    });

    test('a key from someone not paired is not taken', () async {
      await sync.handleIncomingSyncMessage(from('STRANGER', SyncMessageType.timerShare, {
        'timerId': 'timer-x',
        'key': 'KEY',
        'role': 'player',
      }));
      expect(timers.recordOf('timer-x'), isNull);
    });
  });

  test('a change nudge fetches the timer again', () async {
    await timers.addShared(id: 'timer-1', role: TimerRole.player, key: 'K');
    fetched.clear();

    await sync.handleIncomingSyncMessage(
        from('TES123', SyncMessageType.timerChanged, {'timerId': 'timer-1', 'summary': 'Added 1 hour'}));

    expect(fetched.where((u) => u.path.endsWith('/timer/timer-1/view')).length, 1);
  });

  test('the new message types survive the trip through JSON', () {
    for (final type in [SyncMessageType.featureHello, SyncMessageType.timerShare, SyncMessageType.timerChanged]) {
      final decoded = SyncMessage.decode(SyncMessage(type: type, senderId: 'x', payload: {}).encode());
      expect(decoded.type, type);
    }
  });

  group('a second timer while one is running', () {
    final second = PartnerContact(
      id: 'contact-2',
      displayName: 'Sam',
      pairingCode: 'SAM456',
      pairingSecret: 'secret-2',
      role: PartnerRole.dominant,
    );
    final released = <String>[];

    setUp(() async {
      released.clear();
      await partners.addContact(second);
      // Each timer answers as itself; a release is noted.
      ChastityTimerService.request = (method, url, {key, body}) async {
        fetched.add(url);
        final segments = url.pathSegments;
        final id = segments[segments.length - 2];
        if (segments.last == 'release') {
          released.add(id);
          return TimerApiResponse(200, {...view(id, 'director'), 'status': 'released', 'releasedBy': 'director'});
        }
        return TimerApiResponse(200, view(id, key == 'D' ? 'director' : 'player'));
      };
    });

    Future<void> share(String code, String id, {String key = 'P'}) => sync.handleIncomingSyncMessage(
        from(code, SyncMessageType.timerShare, {'timerId': id, 'key': key, 'role': 'player'}));

    test('the first starts straight away; the second waits for the player to say yes', () async {
      await share('TES123', 'timer-1');
      expect(timers.recordOf('timer-1'), isNotNull);

      await share('SAM456', 'timer-2');
      expect(timers.recordOf('timer-2'), isNull, reason: 'not started on them unasked');
      expect(timers.invites.single.id, 'timer-2');
      expect(timers.invites.single.partnerName, 'Sam');
    });

    test('the same timer sent again is not a new request', () async {
      await share('TES123', 'timer-1');
      await share('TES123', 'timer-1', key: 'P2');
      expect(timers.invites, isEmpty);
      expect(timers.recordOf('timer-1')!.key, 'P2');
    });

    test('accepting starts it; the request is gone, across a restart too', () async {
      await share('TES123', 'timer-1');
      await share('SAM456', 'timer-2');
      expect(await timers.acceptInvite('timer-2'), isNotNull);
      expect(timers.recordOf('timer-2')!.partnerName, 'Sam');
      expect(timers.invites, isEmpty);

      final again = ChastityTimerService();
      await again.load();
      expect(again.invites, isEmpty);
      expect(again.recordOf('timer-2'), isNotNull);
    });

    test('a request waits across a restart', () async {
      await share('TES123', 'timer-1');
      await share('SAM456', 'timer-2');
      final again = ChastityTimerService();
      await again.load();
      expect(again.invites.single.id, 'timer-2');
    });

    test("declined, the director's copy ends the timer and says why", () async {
      // The director's side: it sent timer-2 to Sam's player, here 'SAM456'.
      await timers.addShared(id: 'timer-2', role: TimerRole.director, key: 'D', partnerCode: 'SAM456', partnerName: 'Sam');
      await sync.handleIncomingSyncMessage(from('SAM456', SyncMessageType.timerDeclined, {'timerId': 'timer-2'}));
      expect(released, ['timer-2']);
      expect(timers.wasDeclined('timer-2'), isTrue);
    });

    test('only the partner it was sent to can turn it down', () async {
      await timers.addShared(id: 'timer-2', role: TimerRole.director, key: 'D', partnerCode: 'SAM456', partnerName: 'Sam');
      await sync.handleIncomingSyncMessage(from('TES123', SyncMessageType.timerDeclined, {'timerId': 'timer-2'}));
      expect(released, isEmpty);
      expect(timers.wasDeclined('timer-2'), isFalse);
    });
  });
}
