import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/core/security/patreon_access.dart';

/// The real access code is deliberately absent from this public repository,
/// here as everywhere else; these check the list it lives in instead.
void main() {
  test('exactly one code unlocks the Patreon features', () {
    expect(PatreonAccess.validCodeCount, 1);
  });

  test('none of the retired codes still works', () {
    // Nine codes used to work, several of them words anyone would try first.
    for (final retired in [
      'PATREON-VIP',
      'QUESTS-2026',
      'DIRECTIVE-CHAIN',
      'PATREON-SUPPORTER',
      'QUEST',
      'VIP',
      'SCHEDULE',
      'SCHEDULE-VIP',
      'PATREON',
    ]) {
      expect(PatreonAccess.isValid(retired), isFalse, reason: retired);
    }
  });

  test('case and surrounding whitespace do not matter', () {
    expect(PatreonAccess.digestOf('  abc-123 '), PatreonAccess.digestOf('ABC-123'));
  });
}
