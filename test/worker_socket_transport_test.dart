import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/services/worker_socket_service.dart';

/// Desktop's replacement for the public relay.
///
/// A live socket alone is not enough: a PC that was switched off has to be
/// able to collect what it missed, and it must not collect what it already
/// handled. That is what the sequence cursor is for, and it is the part that
/// decides whether this can replace the relay rather than sit beside it.
class FakeChannel implements HubChannel {
  FakeChannel();

  final _controller = StreamController<dynamic>.broadcast();
  final List<String> sent = [];
  bool closed = false;

  void deliver(String frame) => _controller.add(frame);
  void drop() => _controller.close();

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> close() async {
    closed = true;
    if (!_controller.isClosed) await _controller.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const topic = 'topic_hash';
  late List<Uri> opened;
  late List<FakeChannel> channels;
  late List<String> received;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    opened = [];
    channels = [];
    received = [];
  });

  WorkerSocketService serviceUnder({bool registerOk = true}) => WorkerSocketService(
        connector: (url) async {
          opened.add(url);
          final channel = FakeChannel();
          channels.add(channel);
          return channel;
        },
        registrar: (_, __) async => registerOk,
      );

  Future<void> startOn(WorkerSocketService service) => service.start(
        topic: topic,
        clientId: 'client_1',
        onPayload: (raw) async => received.add(raw),
      );

  String frame(int seq, String payload, [String kind = 'sync']) =>
      '{"seq":$seq,"p":"$payload","k":"$kind"}';

  Future<void> settle() => Future.delayed(const Duration(milliseconds: 20));

  test('delivers payloads and remembers how far it got', () async {
    final service = serviceUnder();
    await startOn(service);
    await settle();

    expect(opened.single.queryParameters['topic'], topic);
    expect(opened.single.queryParameters['since'], '0',
        reason: 'a device that has seen nothing asks for everything');
    expect(opened.single.scheme, 'wss');

    channels.single.deliver(frame(1, 'cipher-one'));
    channels.single.deliver(frame(2, 'cipher-two'));
    await settle();

    expect(received, ['cipher-one', 'cipher-two']);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(WorkerSocketService.cursorKey(topic)), 2);

    await service.stop();
  });

  test('reconnects asking only for what it has not handled', () async {
    final service = serviceUnder();
    await startOn(service);
    await settle();
    channels.single.deliver(frame(7, 'cipher-seven'));
    await settle();

    // The machine drops off the network.
    channels.single.drop();
    // Backoff starts at two seconds.
    await Future.delayed(const Duration(seconds: 3));

    expect(opened.length, 2, reason: 'should have reconnected');
    expect(opened.last.queryParameters['since'], '7',
        reason: 'asking from 0 again would replay directives already handled');

    await service.stop();
  });

  test('a malformed frame is skipped without losing the ones after it', () async {
    final service = serviceUnder();
    await startOn(service);
    await settle();

    channels.single.deliver('not json at all');
    channels.single.deliver('{"seq":4}'); // no payload
    channels.single.deliver('pong');
    channels.single.deliver(frame(5, 'cipher-five'));
    await settle();

    expect(received, ['cipher-five']);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(WorkerSocketService.cursorKey(topic)), 5);

    await service.stop();
  });

  test('the cursor only advances once the payload has been handled', () async {
    final failing = WorkerSocketService(
      connector: (url) async {
        opened.add(url);
        final channel = FakeChannel();
        channels.add(channel);
        return channel;
      },
      registrar: (_, __) async => true,
    );
    await failing.start(
      topic: topic,
      clientId: 'client_1',
      onPayload: (raw) async => throw StateError('could not apply'),
    );
    await settle();

    channels.single.deliver(frame(9, 'cipher-nine'));
    await settle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(WorkerSocketService.cursorKey(topic)), isNull,
        reason: 'a directive that could not be applied must arrive again, not be skipped');

    await failing.stop();
  });

  test('stopping closes the socket and stops reconnecting', () async {
    final service = serviceUnder();
    await startOn(service);
    await settle();
    await service.stop();

    expect(channels.single.closed, isTrue);

    channels.single.drop();
    await Future.delayed(const Duration(seconds: 3));
    expect(opened.length, 1, reason: 'a stopped transport must not come back');
  });
}
