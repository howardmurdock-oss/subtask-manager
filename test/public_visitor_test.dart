import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/core/security/proof_crypto.dart';
import 'package:orders_app/services/app_links.dart';
import 'package:orders_app/services/public_visitor_service.dart';

/// This app as a visitor to other people's public timers.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('links', () {
    test('only subtaskmanager:// links, to a timer or a player page', () {
      expect(AppLinks.parse('https://subtaskmanager.com/t/abcdefgh'), isNull);
      final t = AppLinks.publicPageOf(AppLinks.parse('subtaskmanager://t/TwF4KZFeturu')!);
      expect((t!.kind, t.id), ('t', 'TwF4KZFeturu'));
      final p = AppLinks.publicPageOf(AppLinks.parse('subtaskmanager://p/jX9gT6xAqcBX')!);
      expect((p!.kind, p.id), ('p', 'jX9gT6xAqcBX'));
      expect(AppLinks.publicPageOf(AppLinks.parse('subtaskmanager://verified')!), isNull);
      expect(AppLinks.publicPageOf(AppLinks.parse('subtaskmanager://t/../../etc')!), isNull);
    });
  });

  test("proof for this app opens with its own key, and no one else's", () {
    final mine = ProofCrypto.newKeyPair();
    final other = ProofCrypto.newKeyPair();
    final envelope = ProofCrypto.encrypt(mine.publicKey, Uint8List.fromList(utf8.encode('locked')), 'text/plain');
    final opened = ProofCrypto.decrypt(envelope, mine.privateHex);
    expect(utf8.decode(opened.bytes), 'locked');
    expect(opened.mime, 'text/plain');
    expect(() => ProofCrypto.decrypt(envelope, other.privateHex), throwsA(anything));
  });

  group('the visitor', () {
    late List<({String method, String path, Map<String, String>? headers, Object? body})> calls;
    late bool serverVerified;
    late PublicVisitorService visitor;
    String? proofFor;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      calls = [];
      serverVerified = false;
      proofFor = null;
      PublicVisitorService.ownTopic = () => 'orders_relay_0123456789abcdef01234567';
      PublicVisitorService.request = (method, url, {headers, body}) async {
        calls.add((method: method, path: url.path, headers: headers, body: body));
        final device = headers?['X-Device-Id'] == 'dev1' && headers?['X-Device-Secret'] != null;
        switch (url.path) {
          case '/device/start':
            return const VisitorResponse(200, {'deviceId': 'dev1'});
          case '/device/status':
            return VisitorResponse(200, {'verified': device && serverVerified});
        }
        if (url.path.endsWith('/order') || url.path.endsWith('/vote')) {
          if (!(device && serverVerified)) return const VisitorResponse(403, {'error': 'turnstile'});
          return const VisitorResponse(200, {'no': 7});
        }
        if (url.path.endsWith('/proof')) {
          return proofFor == null ? const VisitorResponse(404, {'error': 'no proof'}) : VisitorResponse(200, {'proof': proofFor});
        }
        if (url.path.endsWith('/watch')) return const VisitorResponse(200, {'watching': true});
        return const VisitorResponse(404, {});
      };
      visitor = PublicVisitorService();
      await visitor.load();
    });

    tearDown(() => PublicVisitorService.ownTopic = null);

    test('the first vote asks for the one-time check; after it, no more', () async {
      expect(await visitor.vote('abcdefghijkl', 1), 'verify');

      // The check: registered, then passed in the browser.
      final codeHashes = <Object?>[];
      PublicVisitorService.request = (() {
        final inner = PublicVisitorService.request;
        return (String method, Uri url, {Map<String, String>? headers, Object? body}) {
          if (url.path == '/device/start') codeHashes.add((body as Map)['codeHash']);
          return inner(method, url, headers: headers, body: body);
        };
      })();
      // Opening the browser is not possible here; the registration is what counts.
      try {
        await visitor.startVerification();
      } catch (_) {}
      expect(codeHashes.single, isNot(contains('orders_relay')), reason: 'only a hash of the friend code leaves');
      serverVerified = true;
      expect(await visitor.checkVerified(), isTrue);

      expect(await visitor.vote('abcdefghijkl', 1), isNull);
      final vote = calls.lastWhere((c) => c.path.endsWith('/vote'));
      expect(vote.headers?['X-Device-Id'], 'dev1');
      expect((vote.body as Map).containsKey('turnstileToken'), isFalse);
    });

    test("an order sent from the app: its proof comes back to this app's key", () async {
      serverVerified = true;
      try {
        await visitor.startVerification();
      } catch (_) {}
      await visitor.checkVerified();

      expect(await visitor.sendOrder('abcdefghijkl', {'id': 'check', 'title': 'Cage check'}, proofToSender: true), isNull);
      final sent = calls.lastWhere((c) => c.path.endsWith('/order')).body as Map;
      expect(sent['issuerTopic'], 'orders_relay_0123456789abcdef01234567', reason: 'told here how it goes');
      expect(sent['receiptHash'], hasLength(64));
      final order = visitor.sentOrder('abcdefghijkl', 7)!;
      expect(order.title, 'Cage check');

      // The player's app encrypts the photo to the key that went with it.
      proofFor = ProofCrypto.encrypt(sent['issuerKey'] as String, Uint8List.fromList([0xff, 0xd8, 0xff, 1]), 'image/jpeg');
      final proof = await visitor.proof(order);
      expect(proof?.mime, 'image/jpeg');
      expect(proof?.bytes, [0xff, 0xd8, 0xff, 1]);

      // Kept across a restart: receipt and key both.
      final again = PublicVisitorService();
      await again.load();
      expect((await again.proof(again.sentOrder('abcdefghijkl', 7)!))?.bytes, [0xff, 0xd8, 0xff, 1]);
    });

    test('watching: kept here, and the Worker asked to tell this app when it ends', () async {
      serverVerified = true;
      try {
        await visitor.startVerification();
      } catch (_) {}
      await visitor.checkVerified();
      const page = PublicPage(kind: 'p', id: 'jX9gT6xAqcBX', state: {
        'name': 'PC 1',
        'featured': {'publicId': 'abcdefghijkl', 'status': 'running'},
      });
      await visitor.watch(page, on: true);
      expect(visitor.isWatching('p', 'jX9gT6xAqcBX'), isTrue);
      expect(visitor.watching.single.label, 'PC 1');
      final watch = calls.lastWhere((c) => c.path.endsWith('/watch'));
      expect(watch.path, '/t/abcdefghijkl/watch', reason: "a player page's current timer");
      await visitor.watch(page, on: false);
      expect(visitor.watching, isEmpty);
    });
  });
}
