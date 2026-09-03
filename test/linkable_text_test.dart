import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/widgets/linkable_text.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LinkableText Unit & Widget Tests', () {
    test('buildSpans parses plain text with no links', () {
      final spans = LinkableText.buildSpans(
        text: 'Hello, this is just a normal text message.',
        defaultStyle: const TextStyle(fontSize: 14),
        linkStyle: const TextStyle(color: Colors.blue),
        onTap: (_) {},
      );

      expect(spans.length, equals(1));
      expect(spans.first, isA<TextSpan>());
      expect((spans.first as TextSpan).text, equals('Hello, this is just a normal text message.'));
      expect((spans.first as TextSpan).recognizer, isNull);
    });

    test('buildSpans parses raw https URL correctly', () {
      final spans = LinkableText.buildSpans(
        text: 'Visit https://subtaskmanager.com for app info',
        defaultStyle: const TextStyle(fontSize: 14),
        linkStyle: const TextStyle(color: Colors.blue),
        onTap: (_) {},
      );

      expect(spans.length, equals(3));
      expect((spans[0] as TextSpan).text, equals('Visit '));
      expect((spans[1] as TextSpan).text, equals('https://subtaskmanager.com'));
      expect((spans[1] as TextSpan).recognizer, isNotNull);
      expect((spans[2] as TextSpan).text, equals(' for app info'));
    });

    test('buildSpans parses www URL correctly', () {
      final spans = LinkableText.buildSpans(
        text: 'Check www.google.com for answers',
        defaultStyle: const TextStyle(fontSize: 14),
        linkStyle: const TextStyle(color: Colors.blue),
        onTap: (_) {},
      );

      expect(spans.length, equals(3));
      expect((spans[0] as TextSpan).text, equals('Check '));
      expect((spans[1] as TextSpan).text, equals('www.google.com'));
      expect((spans[1] as TextSpan).recognizer, isNotNull);
      expect((spans[2] as TextSpan).text, equals(' for answers'));
    });

    test('buildSpans parses markdown links correctly', () {
      final spans = LinkableText.buildSpans(
        text: 'Click [Our Website](https://subtaskmanager.com) now!',
        defaultStyle: const TextStyle(fontSize: 14),
        linkStyle: const TextStyle(color: Colors.blue),
        onTap: (_) {},
      );

      expect(spans.length, equals(3));
      expect((spans[0] as TextSpan).text, equals('Click '));
      expect((spans[1] as TextSpan).text, equals('Our Website'));
      expect((spans[1] as TextSpan).recognizer, isNotNull);
      expect((spans[2] as TextSpan).text, equals(' now!'));
    });

    test('buildSpans handles trailing punctuation gracefully', () {
      final spans = LinkableText.buildSpans(
        text: 'Check https://subtaskmanager.com.',
        defaultStyle: const TextStyle(fontSize: 14),
        linkStyle: const TextStyle(color: Colors.blue),
        onTap: (_) {},
      );

      expect(spans.length, equals(3));
      expect((spans[0] as TextSpan).text, equals('Check '));
      expect((spans[1] as TextSpan).text, equals('https://subtaskmanager.com'));
      expect((spans[2] as TextSpan).text, equals('.'));
    });

    TextSpan? findSpanWithText(InlineSpan span, String text) {
      if (span is TextSpan) {
        if (span.text == text) return span;
        if (span.children != null) {
          for (final child in span.children!) {
            final found = findSpanWithText(child, text);
            if (found != null) return found;
          }
        }
      }
      return null;
    }

    testWidgets('Tapping on a link invokes callback with the correct URL', (tester) async {
      String? launchedUrl;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LinkableText(
              text: 'Please visit https://subtaskmanager.com today!',
              onOpenUrl: (url) {
                launchedUrl = url;
              },
            ),
          ),
        ),
      );

      final richTextFinder = find.descendant(
        of: find.byType(LinkableText),
        matching: find.byType(RichText),
      );
      final richText = tester.widget<RichText>(richTextFinder);
      final linkSpan = findSpanWithText(richText.text, 'https://subtaskmanager.com');

      expect(linkSpan, isNotNull);
      expect(linkSpan!.recognizer, isA<TapGestureRecognizer>());

      final recognizer = linkSpan.recognizer as TapGestureRecognizer;
      recognizer.onTap?.call();

      expect(launchedUrl, equals('https://subtaskmanager.com'));
    });

    testWidgets('Tapping on a markdown link invokes callback with the target URL', (tester) async {
      String? launchedUrl;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LinkableText(
              text: 'Open [Direct Link](https://subtaskmanager.com/app) right now',
              onOpenUrl: (url) {
                launchedUrl = url;
              },
            ),
          ),
        ),
      );

      final richTextFinder = find.descendant(
        of: find.byType(LinkableText),
        matching: find.byType(RichText),
      );
      final richText = tester.widget<RichText>(richTextFinder);
      final linkSpan = findSpanWithText(richText.text, 'Direct Link');

      expect(linkSpan, isNotNull);
      expect(linkSpan!.recognizer, isA<TapGestureRecognizer>());

      final recognizer = linkSpan.recognizer as TapGestureRecognizer;
      recognizer.onTap?.call();

      expect(launchedUrl, equals('https://subtaskmanager.com/app'));
    });
  });
}
