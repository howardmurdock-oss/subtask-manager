import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Snippets for putting this public timer on other people's pages: a live
/// widget for websites, and an image for forums, which mostly allow images
/// but not frames. Both say "Timer ended" once it is gone.
void showEmbedSheet(BuildContext context, String link, {bool profile = false}) {
  final snippets = <(String, String, String)>[
    (
      'Website or blog',
      'A live countdown with a Vote button.',
      '<iframe src="$link/embed" width="340" height="150" style="border:0;max-width:100%" title="Chastity Timer"></iframe>',
    ),
    (
      'Forum (BBCode)',
      'For forums that use [img] tags. Shows the time left when the post is loaded.',
      '[url=$link][img]$link/badge.svg[/img][/url]',
    ),
    (
      "Forum, if the image above doesn't show",
      "Some forums don't accept that kind of image. This one always works, but shows the status, not the time.",
      '[url=$link][img]$link/badge.png[/img][/url]',
    ),
    (
      'Markdown',
      'For sites that use Markdown, like many forums and READMEs.',
      '[![Chastity Timer]($link/badge.svg)]($link)',
    ),
    (
      'Website, as an image',
      "For pages that don't allow embeds.",
      '<a href="$link"><img src="$link/badge.svg" alt="Chastity Timer" width="320" height="64"></a>',
    ),
  ];
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Text(profile ? 'Embed your page' : 'Embed this timer', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              profile
                  ? 'Copy one of these into a post or page. They always show your current timer, '
                      'so they keep working from one timer to the next.'
                  : 'Copy one of these into a post or page. If you make a new link, '
                      'embeds of this one will show "Timer ended".',
              style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                children: [
                  Icon(Icons.forum_rounded, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Discord, Slack, iMessage and most chat apps: just paste the link. '
                      'It shows a preview card with the time left.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            for (final (title, about, code) in snippets)
              Card(
                margin: const EdgeInsets.only(top: 10),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 6, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold))),
                          TextButton.icon(
                            icon: const Icon(Icons.copy_rounded, size: 16),
                            label: const Text('Copy'),
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: code));
                              Navigator.pop(ctx);
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('$title code copied.'), behavior: SnackBarBehavior.floating));
                            },
                          ),
                        ],
                      ),
                      Text(about, style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withValues(alpha: 0.65))),
                      const SizedBox(height: 6),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(8),
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SelectableText(code, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}
