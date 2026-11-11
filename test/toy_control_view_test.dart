import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/services/toy/toy_models.dart';
import 'package:orders_app/services/toy/toy_patterns.dart';
import 'package:orders_app/services/toy/toy_player.dart';
import 'package:orders_app/services/toy/toy_remote.dart';
import 'package:orders_app/services/toy/toy_service.dart';
import 'package:orders_app/views/toy/toy_control_view.dart';
import 'package:orders_app/views/toy/toy_partner_sections.dart';

class _Recorder implements ToyOutput {
  final List<int> speeds = [];
  int stops = 0;
  @override
  void setSpeed(int speed) => speeds.add(speed);
  @override
  void stop() => stops++;
}

void main() {
  final toy = ToyService.instance;

  tearDown(() => toy.debugSetConnected(null));

  Future<(ToyPlayer, _Recorder)> pumpPanel(WidgetTester tester, {Size size = const Size(390, 844)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final out = _Recorder();
    final player = ToyPlayer(output: out, patternTick: const Duration(milliseconds: 50));
    final host = ToyRemoteHost(player: player);
    await tester.pumpWidget(MaterialApp(
      home: ToyControlView(target: LocalToyTarget(player: player, host: host)),
    ));
    return (player, out);
  }

  testWidgets('your own toy: patterns play, Stop stills it, fits a phone', (tester) async {
    toy.debugSetConnected(const ConnectedToyInfo(id: 'x', name: 'Test Toy', batteryLevel: 55));
    final (player, out) = await pumpPanel(tester);
    expect(find.text('Test Toy'), findsOneWidget);
    expect(find.text('55%'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('toy-pattern-wave')));
    await tester.tap(find.byKey(const Key('toy-pattern-wave')));
    await tester.pump(const Duration(milliseconds: 120));
    expect(player.activity, ToyActivity.pattern);
    expect(player.pattern, ToyPattern.wave);
    expect(out.speeds, isNotEmpty);

    await tester.scrollUntilVisible(find.byKey(const Key('toy-stop')), -200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('toy-stop')));
    await tester.pump();
    expect(player.activity, ToyActivity.idle);
    expect(out.stops, greaterThan(0));

    await tester.ensureVisible(find.byKey(const Key('toy-pattern-metronome')));
    await tester.tap(find.byKey(const Key('toy-pattern-metronome')));
    await tester.pump();
    await tester.scrollUntilVisible(find.byKey(const Key('toy-metronome-start')), 300,
        scrollable: find.byType(Scrollable).first);
    expect(tester.takeException(), isNull);
    player.stop();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('the metronome is one of the patterns, and there is no Pulse', (tester) async {
    toy.debugSetConnected(const ConnectedToyInfo(id: 'x', name: 'Test Toy', batteryLevel: 55));
    final (player, _) = await pumpPanel(tester);
    expect(find.text('Live metronome'), findsNothing, reason: 'no separate section');
    expect(find.byKey(const Key('toy-pattern-pulse')), findsNothing);
    expect(find.byKey(const Key('toy-metronome-start')), findsNothing, reason: 'settings only once chosen');

    final metronome = find.byKey(const Key('toy-pattern-metronome'));
    await tester.ensureVisible(metronome);
    await tester.tap(metronome);
    await tester.pump();
    expect(find.byKey(const Key('toy-tempo-fixed')), findsOneWidget);
    expect(find.byType(Slider).evaluate().where((e) => (e.widget as Slider).label != null).length, lessThanOrEqualTo(2),
        reason: 'one strength slider for patterns and metronome alike');

    await tester.ensureVisible(find.byKey(const Key('toy-metronome-start')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('toy-metronome-start')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(player.activity, ToyActivity.metronome);

    // Another pattern takes over and folds the metronome away.
    await tester.ensureVisible(find.byKey(const Key('toy-pattern-heartbeat')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const Key('toy-pattern-heartbeat')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(player.activity, ToyActivity.pattern);
    expect(player.pattern, ToyPattern.heartbeat);
    expect(find.byKey(const Key('toy-metronome-start')), findsNothing);
    expect(tester.takeException(), isNull);

    player.stop();
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('without a toy the controls say why and do nothing', (tester) async {
    final (player, _) = await pumpPanel(tester);
    expect(find.text('Connect your toy first.'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('toy-pattern-wave')));
    await tester.tap(find.byKey(const Key('toy-pattern-wave')), warnIfMissed: false);
    await tester.pump();
    expect(player.activity, ToyActivity.idle);
  });

  testWidgets('the banner appears only while a partner is in control', (tester) async {
    final host = ToyRemoteHost(player: ToyPlayer(output: _Recorder()));
    await tester.pumpWidget(MaterialApp(
      home: const Scaffold(body: Text('home')),
      builder: (context, child) => ToyRemoteBanner(host: host, child: child!),
    ));
    expect(find.byKey(const Key('toy-remote-banner')), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });
}
