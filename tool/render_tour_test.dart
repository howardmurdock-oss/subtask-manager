// ignore_for_file: invalid_use_of_visible_for_testing_member
// Pictures of every step of the app tour on a phone, with real fonts, into
// the folder given by TOUR_SHOTS (default: build/tour_shots). Not part of the
// test suite - run it by hand to see the tour:
//
//   flutter test tool/render_tour_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
import 'package:orders_app/views/home_screen.dart';
import 'package:orders_app/views/tour/app_tour.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fonts = r'F:\src\flutter\bin\cache\artifacts\material_fonts';

Future<void> _load(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    final bytes = File('$_fonts\\$f').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('render the tour', (tester) async {
    await tester.runAsync(() async {
      await _load('Roboto', ['roboto-regular.ttf', 'roboto-medium.ttf', 'roboto-bold.ttf']);
      await _load('MaterialIcons', ['materialicons-regular.otf']);
    });
    final previous = FlutterError.onError;
    FlutterError.onError = (d) {
      if (!d.exceptionAsString().contains('overflowed')) previous?.call(d);
    };
    addTearDown(() => FlutterError.onError = previous);

    SharedPreferences.setMockInitialValues({UpdateService.lastCheckedKey: DateTime.now().toIso8601String()});
    UpdateService.fetch = (_) async => null;
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final engine = OrderEngine(storage: StorageService());
    final sync = SyncService(engine);
    final partners = PartnerService();
    final chat = ChatService();
    final quests = QuestService();
    sync.attachServices(partners, chat, questService: quests);
    addTearDown(sync.dispose);
    final theme = ThemeProvider();

    final shot = GlobalKey();
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: theme),
        ChangeNotifierProvider.value(value: SecurityService()),
        ChangeNotifierProvider.value(value: engine),
        ChangeNotifierProvider.value(value: partners),
        ChangeNotifierProvider.value(value: chat),
        ChangeNotifierProvider.value(value: quests),
        ChangeNotifierProvider.value(value: sync),
      ],
      child: RepaintBoundary(
        key: shot,
        child: MaterialApp(theme: theme.themeData, debugShowCheckedModeBanner: false, home: const HomeScreen()),
      ),
    ));

    final out = Directory(Platform.environment['TOUR_SHOTS'] ?? 'build/tour_shots')..createSync(recursive: true);
    Future<void> settle() async {
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> save(int n) async {
      final boundary = shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${out.path}/step_${n.toString().padLeft(2, '0')}.png').writeAsBytesSync(data!.buffer.asUint8List());
      });
    }

    await tester.pump(const Duration(milliseconds: 1500));
    await settle();
    final steps = AppTour.steps();
    await save(1);
    for (var i = 2; i <= steps.length; i++) {
      await tester.tap(find.byKey(const Key('tour-next')));
      await settle();
      await save(i);
    }
    await tester.tap(find.byKey(const Key('tour-done')));
    await settle();
  });
}
