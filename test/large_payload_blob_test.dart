import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/core/security/encryption_helper.dart';
import 'package:orders_app/services/push_service.dart';

/// A proof photo is around 120KB by the time it is compressed, base64'd and
/// encrypted - thirty times what a data message can carry. It therefore could
/// not travel by push at all, and went to the public relay instead, which a
/// dozing Android device never hears: the photo turned up whenever its
/// recipient next opened the app, if the relay had not expired it first.
///
/// So a payload that large is stored with the Worker and a pointer sent in its
/// place. What is stored is the same ciphertext that would have been in the
/// message.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('recognising a pointer', () {
    test('a pointer is recognised and yields its id', () {
      final pointer = PushService.pointerFor('abc123');
      expect(PushService.pointerIdIn(pointer), 'abc123');
    });

    test('ciphertext is never mistaken for one', () {
      final ciphertext = EncryptionHelper.encryptString(
        jsonEncode({'type': 'proofSubmitted', 'photo': 'x' * 200}),
        'a-pairing-secret',
      );
      expect(ciphertext.startsWith('{'), isFalse,
          reason: 'base64 cannot collide with a JSON pointer');
      expect(PushService.pointerIdIn(ciphertext), isNull);
    });

    test('a plain sync message is not a pointer', () {
      final plain = jsonEncode({'type': 'pairingRequest', 'id': 'm1', 'payload': {}});
      expect(PushService.pointerIdIn(plain), isNull);
    });

    test('a malformed or empty pointer is not one', () {
      expect(PushService.pointerIdIn('{"__blob":""}'), isNull);
      expect(PushService.pointerIdIn('{"__blob":{}}'), isNull);
      expect(PushService.pointerIdIn('{"__blob":'), isNull);
    });
  });

  group('resolving', () {
    test('an ordinary payload is returned untouched, without a fetch', () async {
      final ciphertext = EncryptionHelper.encryptString('{"type":"ping"}', 'secret');
      expect(await PushService.resolvePayload(ciphertext), ciphertext);
    });
  });

  test('a proof photo really is too large for a data message', () {
    // Not an assumption worth carrying: a 50KB JPEG, base64'd into the message
    // and then encrypted, against the limit the Worker enforces.
    final photo = base64Encode(List<int>.filled(50 * 1024, 7));
    final message = jsonEncode({
      'type': 'proofSubmitted',
      'id': 'm1',
      'payload': {'proofImageBase64': photo, 'note': 'done'},
    });
    final ciphertext = EncryptionHelper.encryptString(message, 'a-pairing-secret');

    expect(utf8.encode(ciphertext).length, greaterThan(PushService.maxDataMessageBytes));
    expect(utf8.encode(PushService.pointerFor('0' * 64)).length,
        lessThan(PushService.maxDataMessageBytes),
        reason: 'the pointer sent in its place must fit');
  });
}
