import 'package:flutter/material.dart';
import '../views/player/rewards_shop_view.dart';

class TokenBadge extends StatelessWidget {
  final int tokens;
  final int streakDays;
  final VoidCallback? onTap;

  const TokenBadge({
    super.key,
    required this.tokens,
    this.streakDays = 0,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap ??
          () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const RewardsShopView()),
            );
          },
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: theme.colorScheme.primary.withOpacity(0.3),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.toll_rounded,
              size: 16,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Text(
              '$tokens',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color: theme.colorScheme.onSurface,
              ),
            ),
            if (streakDays > 0) ...[
              const SizedBox(width: 10),
              Container(
                width: 1,
                height: 12,
                color: theme.colorScheme.onSurface.withOpacity(0.2),
              ),
              const SizedBox(width: 10),
              const Icon(
                Icons.local_fire_department_rounded,
                size: 16,
                color: Colors.amber,
              ),
              const SizedBox(width: 4),
              Text(
                '$streakDays',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: Colors.amber,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
