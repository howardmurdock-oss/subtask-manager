import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/models/chastity_timer.dart';
import 'package:orders_app/services/chastity_timer_service.dart';
import 'package:orders_app/services/chat_service.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/quest_service.dart';
import 'package:orders_app/services/storage_service.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/services/timer_presets.dart';
import 'package:orders_app/views/chastity_timer/timer_setup_view.dart';

/// Saved timer setups, to start the next timer from.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late OrderEngine engine;
  late PartnerService partners;
  late SyncService sync;
  late ChastityTimerService timers;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    engine = OrderEngine(storage: StorageService());
    await engine.init();
    partners = PartnerService();
    await partners.init();
    final chat = ChatService();
    await chat.init();
    sync = SyncService(engine)..attachServices(partners, chat, questService: QuestService());
    timers = ChastityTimerService();
    sync.attachTimerService(timers);
  });

  test("kept per role, replaced by name, and never with a combination's digits", () async {
    await TimerPresets.save('Weekend', TimerRole.player, {'base': 3600, 'comboDigits': '4821', 'partnerCode': 'X'});
    await TimerPresets.save('Weekend', TimerRole.director, {'base': 7200});
    await TimerPresets.save('weekend ', TimerRole.player, {'base': 5400});

    final mine = await TimerPresets.all(role: TimerRole.player);
    expect(mine.single.settings, {'base': 5400}, reason: 'the same name replaced it');
    expect((await TimerPresets.all(role: TimerRole.director)).single.settings['base'], 7200);

    await TimerPresets.save('Other', TimerRole.player, {'base': 1, 'comboDigits': '1234', 'combination': '1234'});
    final other = (await TimerPresets.all(role: TimerRole.player)).firstWhere((p) => p.name == 'Other');
    expect(other.settings.keys, ['base']);

    await TimerPresets.delete(other.id);
    expect((await TimerPresets.all()).length, 2);
  });

  testWidgets('saved settings fill the setup screen back in', (tester) async {
    await TimerPresets.save('Long weekend', TimerRole.player, {
      'base': 3 * 86400,
      'publicOn': true,
      'comboOn': true,
      'comboLength': 6,
      'comboGenerate': true,
      'notice': '{time} more, Toy',
    });

    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: engine),
        ChangeNotifierProvider.value(value: partners),
        ChangeNotifierProvider.value(value: sync),
        ChangeNotifierProvider.value(value: timers),
      ],
      child: const MaterialApp(home: TimerSetupView(role: TimerRole.player)),
    ));
    await tester.pump();

    await tester.tap(find.text('Saved settings'));
    await tester.pumpAndSettle();
    expect(find.text('Long weekend'), findsOneWidget);
    expect(find.text('3 days · public link · combination'), findsOneWidget);
    await tester.tap(find.text('Long weekend'));
    await tester.pumpAndSettle();

    expect(find.text('3 days'), findsWidgets, reason: 'the length is back');
    expect(find.text('Share a public link').evaluate().isNotEmpty || find.text('Let anyone with the link vote').evaluate().isNotEmpty,
        isTrue);
    final list = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first;
    await tester.scrollUntilVisible(find.text('Generate one for me'), 300, scrollable: list);
    expect(find.text('6'), findsOneWidget, reason: 'six digits, freshly generated');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });
}
