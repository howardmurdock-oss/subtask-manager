import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class LinkableText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final TextStyle? linkStyle;
  final void Function(String url)? onOpenUrl;

  const LinkableText({
    super.key,
    required this.text,
    this.style,
    this.linkStyle,
    this.onOpenUrl,
  });

  static final RegExp _linkRegex = RegExp(
    r"\[([^\]]+)\]\(((?:https?:\/\/|www\.)[^\s\)]+)\)|((?:https?:\/\/|www\.)[^\s<]+[^<.,:;'\)\]\s])",
    caseSensitive: false,
  );

  static Future<void> launchLink(String rawUrl) async {
    var url = rawUrl.trim();
    if (!url.startsWith(RegExp(r'^[a-zA-Z]+:\/\/'))) {
      url = 'https://$url';
    }
    final uri = Uri.tryParse(url);
    if (uri != null) {
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final defaultStyle = style ?? const TextStyle(fontSize: 14);
    final effectiveLinkStyle = linkStyle ??
        defaultStyle.copyWith(
          color: theme.colorScheme.primary,
          decoration: TextDecoration.underline,
          decorationColor: theme.colorScheme.primary,
          fontWeight: FontWeight.w500,
        );

    final spans = buildSpans(
      text: text,
      defaultStyle: defaultStyle,
      linkStyle: effectiveLinkStyle,
      onTap: onOpenUrl ?? launchLink,
    );

    return Text.rich(
      TextSpan(children: spans),
    );
  }

  static List<InlineSpan> buildSpans({
    required String text,
    required TextStyle defaultStyle,
    required TextStyle linkStyle,
    required void Function(String url) onTap,
  }) {
    final List<InlineSpan> spans = [];
    int lastMatchEnd = 0;

    final matches = _linkRegex.allMatches(text);

    for (final match in matches) {
      if (match.start > lastMatchEnd) {
        spans.add(TextSpan(
          text: text.substring(lastMatchEnd, match.start),
          style: defaultStyle,
        ));
      }

      String displayText;
      String targetUrl;

      if (match.group(1) != null && match.group(2) != null) {
        // Markdown link [DisplayText](targetUrl)
        displayText = match.group(1)!;
        targetUrl = match.group(2)!;
      } else {
        // Raw URL
        displayText = match.group(3)!;
        targetUrl = match.group(3)!;
      }

      spans.add(
        TextSpan(
          text: displayText,
          style: linkStyle,
          mouseCursor: SystemMouseCursors.click,
          recognizer: TapGestureRecognizer()..onTap = () => onTap(targetUrl),
        ),
      );

      lastMatchEnd = match.end;
    }

    if (lastMatchEnd < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastMatchEnd),
        style: defaultStyle,
      ));
    }

    return spans;
  }
}
