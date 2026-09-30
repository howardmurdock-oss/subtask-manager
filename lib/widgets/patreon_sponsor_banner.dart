import 'package:flutter/material.dart';

import '../core/community_links.dart';

/// Shown to a director using a Patreon feature through a player's support:
/// whose support it is, what it covers, and how to have it for everyone.
class PatreonSponsorBanner extends StatelessWidget {
  const PatreonSponsorBanner({
    super.key,
    required this.supporterNames,
    required this.whatYouCanDo,
  });

  final List<String> supporterNames;

  /// Given the supporters' names as one phrase ("Tessa", "Tessa and PC 1"),
  /// what this covers, e.g. "You can build quests and send them to Tessa."
  final String Function(String names) whatYouCanDo;

  static String joinNames(List<String> names) {
    if (names.isEmpty) return 'your partner';
    if (names.length == 1) return names.single;
    return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = joinNames(supporterNames);
    final possessive = supporterNames.length == 1 ? "$names's" : "$names'";
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.workspace_premium_rounded, color: Colors.amber, size: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Unlocked by $possessive Patreon support',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                Text.rich(
                  TextSpan(
                    style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withValues(alpha: 0.8)),
                    children: [
                      TextSpan(text: '${whatYouCanDo(names)} Unlock this feature with everyone by subscribing to our '),
                      WidgetSpan(
                        alignment: PlaceholderAlignment.baseline,
                        baseline: TextBaseline.alphabetic,
                        child: InkWell(
                          onTap: () => CommunityLinks.open(CommunityLinks.patreon),
                          child: Text(
                            'Patreon here',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: Colors.amber[400],
                              decoration: TextDecoration.underline,
                              decorationColor: Colors.amber[400],
                            ),
                          ),
                        ),
                      ),
                      const TextSpan(text: '.'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
