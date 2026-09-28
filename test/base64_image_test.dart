import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/widgets/base64_image.dart';

/// Two different 1x1 PNGs.
const _red =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==';
const _blue =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPj/HwADBwIAMCbHYQAAAABJRU5ErkJggg==';

void main() {
  // Proof photos on the dashboards were decoded in build, and the dashboards
  // rebuild every second for their countdowns: each rebuild was a new image,
  // reloaded from scratch.
  Future<void> show(WidgetTester tester, String photo, {int rebuild = 0}) =>
      tester.pumpWidget(MaterialApp(
        home: Column(children: [
          // Changes on every call, so the photo's parent really rebuilds.
          Text('tick $rebuild'),
          Base64Image(photo, width: 10, height: 10),
        ]),
      ));

  MemoryImage shown(WidgetTester tester) =>
      tester.widget<Image>(find.byType(Image)).image as MemoryImage;

  testWidgets('the same photo stays the same image across rebuilds', (tester) async {
    await show(tester, _red);
    final before = shown(tester);

    // A copy with equal content, as a sync re-parsing the order would give.
    await show(tester, String.fromCharCodes(_red.codeUnits), rebuild: 1);

    expect(identical(shown(tester).bytes, before.bytes), isTrue,
        reason: 'rebuilding must not decode the photo again');
    expect(tester.widget<Image>(find.byType(Image)).gaplessPlayback, isTrue);
  });

  testWidgets('a different photo is shown when it changes', (tester) async {
    await show(tester, _red);
    final before = shown(tester);

    await show(tester, _blue, rebuild: 1);

    expect(identical(shown(tester).bytes, before.bytes), isFalse);
  });
}
