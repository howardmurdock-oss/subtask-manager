// Build check for flutter_webrtc: two peer connections in one process,
// a data channel between them, a round trip, then exit with a verdict.
//   flutter run -d windows -t tool/webrtc_probe/main.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('WebRTC probe…')))));
  try {
    final result = await _probe().timeout(const Duration(seconds: 30));
    stdout.writeln('PROBE OK $result');
    exit(0);
  } catch (e, st) {
    stdout.writeln('PROBE FAILED $e\n$st');
    exit(1);
  }
}

Future<String> _probe() async {
  final config = {
    'iceServers': [
      {'urls': 'stun:stun.cloudflare.com:3478'},
    ],
  };
  final a = await createPeerConnection(config);
  final b = await createPeerConnection(config);
  a.onIceCandidate = (c) => b.addCandidate(c);
  b.onIceCandidate = (c) => a.addCandidate(c);

  final received = Completer<String>();
  final echoed = Completer<String>();
  b.onDataChannel = (ch) {
    ch.onMessage = (m) {
      if (!received.isCompleted) received.complete(m.text);
      ch.send(RTCDataChannelMessage('echo:${m.text}'));
    };
  };

  final channel = await a.createDataChannel('toy', RTCDataChannelInit()..ordered = true);
  final opened = Completer<void>();
  channel.onDataChannelState = (s) {
    if (s == RTCDataChannelState.RTCDataChannelOpen && !opened.isCompleted) opened.complete();
  };
  channel.onMessage = (m) {
    if (!echoed.isCompleted) echoed.complete(m.text);
  };

  final offer = await a.createOffer();
  await a.setLocalDescription(offer);
  await b.setRemoteDescription(offer);
  final answer = await b.createAnswer();
  await b.setLocalDescription(answer);
  await a.setRemoteDescription(answer);

  final started = Stopwatch()..start();
  await opened.future;
  final openMs = started.elapsedMilliseconds;

  final rtt = Stopwatch()..start();
  await channel.send(RTCDataChannelMessage('{"t":"level","v":9}'));
  final got = await received.future;
  final back = await echoed.future;
  final rttMs = rtt.elapsedMilliseconds;

  // Which kinds of address were gathered: host, srflx (via STUN), relay.
  final kinds = <String>{};
  for (final r in await a.getStats()) {
    if (r.type == 'local-candidate') kinds.add('${r.values['candidateType']}');
  }

  await channel.close();
  await a.close();
  await b.close();
  return 'open=${openMs}ms rtt=${rttMs}ms got=$got back=$back candidates=$kinds';
}
