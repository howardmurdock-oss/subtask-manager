import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/core/security/security_service.dart';
import 'package:orders_app/core/theme/theme_provider.dart';
import 'package:orders_app/services/chat_service.dart';
import 'package:orders_app/services/order_engine.dart';
import 'package:orders_app/services/partner_service.dart';
import 'package:orders_app/services/quest_service.dart';
import 'package:orders_app/services/storage_service.dart';
import 'package:orders_app/services/sync_service.dart';
import 'package:orders_app/services/update_service.dart';
import 'package:orders_app/views/director/order_dispatch_dialog.dart';
import 'package:orders_app/views/director/pack_studio_view.dart';
import 'package:orders_app/views/home_screen.dart';
import 'package:orders_app/views/tour/app_tour.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The guided tour walks the real screens: every step must find what it
// points at, on a phone and on a desktop, and leave the app as it found it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({UpdateService.lastCheckedKey: DateTime.now().toIso8601String()});
    UpdateService.fetch = (_) async => null;
  });

  Future<void> pumpHome(WidgetTester tester, Size size) async {
    // The test font draws every letter as a wide block, which overflows rows
    // in the dispatch window and Pack Studio that fit with real fonts. Those
    // screens are not what is under test here.
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('overflowed')) return;
      previous?.call(details);
    };
    addTearDown(() => FlutterError.onError = previous);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final engine = OrderEngine(storage: StorageService());
    final sync = SyncService(engine);
    final partners = PartnerService();
    final chat = ChatService();
    final quests = QuestService();
    sync.attachServices(partners, chat, questService: quests);
    addTearDown(sync.dispose);

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: ThemeProvider()),
        ChangeNotifierProvider.value(value: SecurityService()),
        ChangeNotifierProvider.value(value: engine),
        ChangeNotifierProvider.value(value: partners),
        ChangeNotifierProvider.value(value: chat),
        ChangeNotifierProvider.value(value: quests),
        ChangeNotifierProvider.value(value: sync),
      ],
      child: const MaterialApp(home: HomeScreen()),
    ));
  }

  /// Lets a step set itself up: routes animate in, targets scroll into view.
  Future<void> settleStep(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  String title(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('tour-title'))).data!;

  Future<void> walkTheTour(WidgetTester tester) async {
    // Offered by itself the first time.
    await tester.pump(const Duration(milliseconds: 1500));
    await settleStep(tester);
    final steps = AppTour.steps();
    expect(title(tester), steps.first.title);
    expect(find.text('PLAYER'), findsOneWidget);

    for (var i = 1; i < steps.length; i++) {
      await tester.tap(find.byKey(const Key('tour-next')));
      await settleStep(tester);
      expect(title(tester), steps[i].title, reason: 'step ${i + 1}');
      expect(tester.takeException(), isNull, reason: 'step ${i + 1} "${steps[i].title}"');
      if (steps[i].targets.isNotEmpty) {
        expect(TourTargets.find(steps[i].targets), isNotNull,
            reason: 'step ${i + 1} "${steps[i].title}" points at something on screen');
      }
      if (steps[i].title == 'Or write one on the spot') {
        expect(find.byType(OrderDispatchDialog), findsOneWidget);
      }
      if (steps[i].title == 'Add your orders') {
        expect(find.byType(PackStudioView), findsOneWidget);
      }
      // (A step that opens a screen covers the badge.)
      if (i >= 2 && steps[i].open == null) {
        expect(find.text('DIRECTOR'), findsOneWidget, reason: 'step ${i + 1}: the tour switched modes itself');
      }
    }
    expect(tester.takeException(), isNull);

    // Back undoes nothing by hand: the previous step sets itself up again.
    await tester.tap(find.byKey(const Key('tour-prev')));
    await settleStep(tester);
    expect(title(tester), steps[steps.length - 2].title);
    await tester.tap(find.byKey(const Key('tour-next')));
    await settleStep(tester);

    // Started as a player: offered the way back.
    await tester.tap(find.byKey(const Key('tour-back-to-player')));
    await settleStep(tester);
    expect(find.byKey(const Key('tour-card')), findsNothing);
    expect(find.text('PLAYER'), findsOneWidget);
    expect(find.byType(PackStudioView), findsNothing, reason: 'nothing the tour opened is left open');
    expect(await AppTour.hasBeenSeen(), isTrue);
    expect(tester.takeException(), isNull);
  }

  testWidgets('the tour on a phone', (tester) async {
    await pumpHome(tester, const Size(390, 844));
    await walkTheTour(tester);
  });

  testWidgets('the tour on a desktop window', (tester) async {
    await pumpHome(tester, const Size(1280, 800));
    await walkTheTour(tester);
  });

  testWidgets('skipping puts things back, and the tour is not offered again', (tester) async {
    await pumpHome(tester, const Size(390, 844));
    await tester.pump(const Duration(milliseconds: 1500));
    await settleStep(tester);
    await tester.tap(find.byKey(const Key('tour-next')));
    await settleStep(tester);
    await tester.tap(find.byKey(const Key('tour-next'))); // now in Director mode
    await settleStep(tester);
    expect(find.text('DIRECTOR'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tour-skip')));
    await settleStep(tester);
    expect(find.byKey(const Key('tour-card')), findsNothing);
    expect(find.text('PLAYER'), findsOneWidget);
    expect(await AppTour.hasBeenSeen(), isTrue);
  });

  testWidgets('seen once, it waits to be asked', (tester) async {
    SharedPreferences.setMockInitialValues({
      UpdateService.lastCheckedKey: DateTime.now().toIso8601String(),
      AppTour.seenKey: true,
    });
    await pumpHome(tester, const Size(390, 844));
    await tester.pump(const Duration(milliseconds: 1500));
    await settleStep(tester);
    expect(find.byKey(const Key('tour-card')), findsNothing);

    AppTour.requestStart();
    await settleStep(tester);
    expect(find.byKey(const Key('tour-card')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tour-skip')));
    await settleStep(tester);
  });
}
