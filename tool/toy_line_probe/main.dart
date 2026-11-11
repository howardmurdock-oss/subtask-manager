// End-to-end check of a toy session's direct line: the app's own owner and
// partner sides, through the live Worker room and Cloudflare TURN.
//   flutter run -d windows --release -t tool/toy_line_probe/main.dart
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:orders_app/models/partner_contact.dart';
import 'package:orders_app/services/toy/toy_models.dart';
import 'package:orders_app/services/toy/toy_peer.dart';
import 'package:orders_app/services/toy/toy_remote.dart';
import 'package:orders_app/services/toy/toy_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Ctx implements ToyRemoteContext {
  _Ctx(this.partners, this.topic);
  @override
  final List<PartnerContact> partners;
  final String topic;
  @override
  String get myCode => 'PROBEOWNER';
  @override
  String get myName => 'Probe owner';
  @override
  Future<void> sendToyStatus(PartnerContact partner, {required bool online, String? toyName}) async {}
  @override
  String topicFor(String code) => topic;
}

/// Counts what the two sides say about the line, by kind.
class _CountingPeer extends WebRtcToyPeer {
  _CountingPeer(this.side, this.log);
  final String side;
  final List<String> log;
  @override
  Future<void> start({required bool offerer}) {
    log.add('$side start offerer=$offerer');
    final out = onSignal;
    onSignal = (sg) {
      log.add('$side sent ${sg['k']} ${sg['sdp']?.toString().length ?? sg['c']?.toString().length}');
      out?.call(sg);
    };
    final closed = onClosed;
    onClosed = () {
      log.add('$side closed');
      closed?.call();
    };
    return super.start(offerer: offerer).then((_) => log.add('$side started open=$isOpen'));
  }

  @override
  void handleSignal(Map<String, dynamic> signal) {
    log.add('$side got ${signal['k']}');
    super.handleSignal(signal);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('toy line probe')))));
  // Never the real app's settings.
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({});
  final log = <String>[];
  var made = 0;
  ToyPeer.factory = () => _CountingPeer(made++ == 0 ? 'panel' : 'owner', log);

  final r = Random.secure();
  final topic = 'probe${List.generate(20, (_) => r.nextInt(36).toRadixString(36)).join()}';
  const secret = 'probe-shared-secret-0123456789';
  final partner = PartnerContact(displayName: 'Probe partner', pairingCode: 'PROBECTL1', pairingSecret: secret);
  final ownerSeen = PartnerContact(displayName: 'Probe owner', pairingCode: 'PROBEOWNER', pairingSecret: secret);

  // ignore: invalid_use_of_visible_for_testing_member
  ToyService.instance.debugSetConnected(const ConnectedToyInfo(id: 'probe', name: 'Probe toy', batteryLevel: 50));
  final host = ToyRemoteHost();
  await host.start(_Ctx([partner], topic));
  await host.setAllowed(partner, true);

  final ctl = ToyRemoteController(partner: ownerSeen, topic: topic);
  final sw = Stopwatch()..start();
  await ctl.open();
  String verdict;
  while (true) {
    if (ctl.direct && host.isDirect(partner)) {
      verdict = 'PROBE OK direct after ${sw.elapsedMilliseconds}ms';
      break;
    }
    if (sw.elapsed > const Duration(seconds: 30)) {
      verdict =
          'PROBE FAILED no direct line after 30s: panelDirect=${ctl.direct} ownerDirect=${host.isDirect(partner)} '
          'connected=${ctl.connected} ownerOnline=${ctl.ownerOnline} denied=${ctl.denied} state=${ctl.state != null}';
      break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  stdout.writeln(verdict);
  stdout.writeln('PROBE peers made: $made; ice now: ${(await ToyIce.servers())?.length}');
  stdout.writeln('PROBE log: ${log.take(30).join(' / ')}');
  if (ctl.direct) {
    ctl.setLevel(7);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    stdout.writeln('PROBE level over line: speed=${ToyService.instance.currentSpeed} '
        'controller=${host.controller?.displayName} panelSees=${ctl.state?.level}');
  }
  await ctl.close();
  await host.stopService();
  exit(0);
}
