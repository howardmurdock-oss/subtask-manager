import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/services/toy/toy_models.dart';
import 'package:orders_app/services/toy/toy_remote.dart';
import 'package:orders_app/services/toy/toy_service.dart';
import 'package:orders_app/views/toy/toy_control_view.dart';
import 'package:orders_app/views/toy/toy_partner_sections.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Ctx implements ToyRemoteContext {
  _Ctx(this.partners);
  @override
  final List<PartnerContact> partners;
  @override
  String get myCode => '';
  @override
  String get myName => 'Me';
  @override
  Future<void> sendToyStatus(PartnerContact partner, {required bool online, String? toyName}) async {}
  @override
  String topicFor(String code) => 'topic-$code';
}

// A player reaches their own toy from the main screen, not Settings.
void main() {
  final toy = ToyService.instance;
  final alex = PartnerContact(displayName: 'Alex', pairingCode: 'ALEX01', pairingSecret: 'secret-a');

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    toy.debugSetConnected(null);
    toy.debugSetRemembered(null);
  });

  Future<ToyRemoteHost> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final host = ToyRemoteHost();
    // myCode is empty, so allowing a partner never opens a real room.
    await host.start(_Ctx([alex]));
    addTearDown(host.stopService);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ListView(children: [YourToyDashboardCard(host: host)])),
    ));
    return host;
  }

  String status(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('dashboard-your-toy-status'))).data!;

  testWidgets('nothing for someone who has never connected a toy', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('dashboard-your-toy')), findsNothing);
  });

  testWidgets('a remembered toy that is off offers Connect', (tester) async {
    toy.debugSetRemembered('Lush 3');
    await pump(tester);
    expect(find.text('Lush 3'), findsOneWidget);
    expect(status(tester), 'Not connected');
    expect(find.byKey(const Key('dashboard-your-toy-connect')), findsOneWidget);
    expect(find.byKey(const Key('dashboard-your-toy-control')), findsNothing);
  });

  testWidgets('connected: Control opens the panel, and it says who else can', (tester) async {
    toy.debugSetConnected(const ConnectedToyInfo(id: 'x', name: 'Lush 3', batteryLevel: 72));
    final host = await pump(tester);
    expect(find.text('72%'), findsOneWidget);
    expect(status(tester), 'Only you can control it');

    await host.setAllowed(alex, true);
    await tester.pump();
    expect(status(tester), 'Partners can control it');
    await host.setPaused(true);
    await tester.pump();
    expect(status(tester), 'Partner control paused');
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('dashboard-your-toy-control')));
    await tester.pumpAndSettle();
    expect(find.byType(ToyControlView), findsOneWidget);
  });
}
