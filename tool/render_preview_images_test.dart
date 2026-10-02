// Draws the link-preview and forum images the Worker serves for public timers,
// into worker/src/images/. Not part of the test suite - run it by hand when
// the design changes:
//
//   flutter test tool/render_preview_images_test.dart
//
// It uses Flutter's test renderer only because that draws real text to a PNG
// with nothing extra installed. Fonts are Windows' Segoe UI.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _bg = Color(0xFF0E0F14);
const _card = Color(0xFF171922);
const _line = Color(0xFF262A36);
const _text = Color(0xFFEEF0F6);
const _muted = Color(0xFF9AA0B4);
const _accent = Color(0xFF22D3EE);
const _pink = Color(0xFFF472B6);
const _green = Color(0xFF34D399);

class _State {
  const _State(this.file, this.tone, this.headline, this.detail, this.badgeDetail, {this.open = false});
  final String file;
  final Color tone;
  final String headline;
  final String detail;

  /// The forum image's shorter line, matching the SVG badge.
  final String badgeDetail;
  final bool open;
}

/// A padlock, closed or open.
class _Lock extends CustomPainter {
  _Lock(this.tone, {required this.open});
  final Color tone;
  final bool open;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final stroke = Paint()
      ..color = tone
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.11
      ..strokeCap = StrokeCap.round;
    final body = RRect.fromRectAndRadius(Rect.fromLTWH(0.06 * w, 0.44 * h, 0.88 * w, 0.52 * h), Radius.circular(w * 0.14));
    canvas.drawRRect(body, Paint()..color = tone.withValues(alpha: 0.2));
    canvas.drawRRect(body, stroke);
    final shackle = Path()
      ..moveTo(0.26 * w, 0.44 * h)
      ..lineTo(0.26 * w, 0.30 * h)
      ..arcToPoint(Offset(0.74 * w, 0.30 * h), radius: Radius.circular(0.24 * w));
    if (open) {
      shackle.lineTo(0.74 * w, 0.22 * h);
    } else {
      shackle.lineTo(0.74 * w, 0.44 * h);
    }
    canvas.drawPath(open ? (shackle.shift(Offset(0, -0.08 * h))) : shackle, stroke);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

const _font = 'SegoeUI';

TextStyle _style(double size, Color color, {FontWeight weight = FontWeight.w700, double spacing = 0}) =>
    TextStyle(fontFamily: _font, fontSize: size, color: color, fontWeight: weight, letterSpacing: spacing, height: 1.15);

/// The link preview: 800x418, what Discord, Slack and others show for a link.
Widget _preview(_State s) => Container(
      width: 800,
      height: 418,
      color: _bg,
      padding: const EdgeInsets.all(28),
      child: Container(
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: _line, width: 2),
        ),
        padding: const EdgeInsets.fromLTRB(56, 48, 56, 44),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('CHASTITY TIMER', style: _style(22, _accent, spacing: 4)),
            const Spacer(),
            Row(
              children: [
                SizedBox(width: 92, height: 104, child: CustomPaint(painter: _Lock(s.tone, open: s.open))),
                const SizedBox(width: 32),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.headline, style: _style(60, _text, weight: FontWeight.w800)),
                      const SizedBox(height: 8),
                      Text(s.detail, style: _style(26, _muted, weight: FontWeight.w400)),
                    ],
                  ),
                ),
              ],
            ),
            const Spacer(),
            Text('subtaskmanager.com', style: _style(22, s.tone, weight: FontWeight.w600)),
          ],
        ),
      ),
    );

/// The forum image: the SVG badge's design at twice its size, 640x128.
Widget _badge(_State s) => Container(
      width: 640,
      height: 128,
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: _line, width: 2),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 30),
      child: Row(
        children: [
          SizedBox(width: 52, height: 60, child: CustomPaint(painter: _Lock(s.tone, open: s.open))),
          const SizedBox(width: 26),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('CHASTITY TIMER', style: _style(17, _accent, spacing: 2.5)),
                const SizedBox(height: 2),
                Text(s.headline, style: _style(34, _text, weight: FontWeight.w800)),
                Text(s.badgeDetail, style: _style(19, _muted, weight: FontWeight.w400), maxLines: 1),
              ],
            ),
          ),
        ],
      ),
    );

/// The website's own link preview, 1200x630 - the standard size for the
/// large cards Discord, X, Slack and Facebook show. Written to
/// build/og-image.png, to be copied into website/assets on main. Kept free of
/// dates, so it never goes stale.
Widget _site() {
  Widget chip(String text, Color tone) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        decoration: BoxDecoration(
          color: tone.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(40),
          border: Border.all(color: tone.withValues(alpha: 0.55), width: 2),
        ),
        child: Text(text, style: _style(26, _text, weight: FontWeight.w600)),
      );
  return Container(
    width: 1200,
    height: 630,
    color: _bg,
    padding: const EdgeInsets.all(40),
    child: Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(36),
        border: Border.all(color: _line, width: 2),
      ),
      padding: const EdgeInsets.fromLTRB(72, 64, 72, 56),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(TextSpan(children: [
            TextSpan(text: '(sub)', style: _style(84, _accent, weight: FontWeight.w800)),
            TextSpan(text: 'Task Manager', style: _style(84, _text, weight: FontWeight.w800)),
          ])),
          const SizedBox(height: 10),
          Text('The task app for dominants and submissives', style: _style(40, _muted, weight: FontWeight.w600)),
          const Spacer(),
          Wrap(spacing: 14, runSpacing: 14, children: [
            chip('Orders', _accent),
            chip('Rewards & punishments', _pink),
            chip('Quests', _accent),
            chip('Scheduled tasks', _accent),
            chip('Chastity timer', _pink),
          ]),
          const Spacer(),
          Row(
            children: [
              Expanded(
                child: Text('Free on Windows, Mac, Linux & Android · End-to-end encrypted',
                    style: _style(24, _muted, weight: FontWeight.w400)),
              ),
              Text('subtaskmanager.com', style: _style(26, _accent, weight: FontWeight.w700)),
            ],
          ),
        ],
      ),
    ),
  );
}

const _states = [
  // One picture for every timer, so nothing that only some allow: "add or
  // take away" would be wrong where removing is off.
  _State('locked', _pink, 'Locked up', 'Vote on how long it lasts', 'Click to vote · subtaskmanager.com'),
  _State('unlocked', _green, 'Unlocked', 'This timer is over', 'This timer is over · subtaskmanager.com', open: true),
  _State('ended', _accent, 'Timer ended', 'Get (sub)Task Manager to run your own',
      'Get (sub)Task Manager · subtaskmanager.com', open: true),
];

Future<void> _load(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    // Read synchronously: file I/O never completes under the test's fake clock.
    final bytes = File(f).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

void main() {
  testWidgets('render the preview and forum images', (tester) async {
    await tester.runAsync(() => _load(_font, [
      r'C:\Windows\Fonts\segoeui.ttf',
      r'C:\Windows\Fonts\seguisb.ttf',
      r'C:\Windows\Fonts\segoeuib.ttf',
      r'C:\Windows\Fonts\seguibl.ttf',
    ]));
    final out = Directory('worker/src/images')..createSync(recursive: true);

    Future<void> render(Widget widget, Size size, String name) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final key = GlobalKey();
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: RepaintBoundary(key: key, child: widget)),
      ));
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final bytes = await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data!.buffer.asUint8List();
      });
      File('${out.path}/$name.png').writeAsBytesSync(bytes!);
    }

    // The website's own preview image: copied into website/assets on main.
    await render(_site(), const Size(1200, 630), '../../../build/og-image');

    for (final s in _states) {
      await render(_preview(s), const Size(800, 418), 'preview-${s.file}');
      await render(_badge(s), const Size(640, 128), 'badge-${s.file}');
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
