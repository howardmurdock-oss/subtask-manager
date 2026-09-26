import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The relay HTTP clients used to accept any certificate at all, so anyone on
/// the network path could stand in for the relay: drop or inject messages,
/// and read a pairing secret back when those still travelled in the clear.
/// The relay WebSockets never had the bypass, so a relay without a valid
/// certificate could not deliver to this app anyway; the bypass bought
/// nothing but exposure.
///
/// The test binding fakes every HTTP request, so a real handshake cannot be
/// tried here. This keeps the bypass from coming back instead. If a relay
/// ever truly needs a self-signed certificate, trust that one certificate
/// for that one host through a SecurityContext rather than switching
/// verification off.
void main() {
  test('no HTTP client in the app accepts certificates it cannot verify', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('badCertificateCallback') ||
            lines[i].contains('onBadCertificate')) {
          offenders.add('${entity.path}:${i + 1}');
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
