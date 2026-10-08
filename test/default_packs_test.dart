import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/models/order_item.dart';
import 'package:orders_app/services/storage_service.dart';

/// The orders new installs start with.
void main() {
  test('every cage check asks for a photo, as its description says', () {
    final checks = StorageService.getDefaultPacks()
        .expand((p) => p.orders)
        .where((o) => o.title.startsWith('Cage Check'))
        .toList();
    expect(checks.length, 4);
    for (final check in checks) {
      expect(check.verificationType, VerificationType.photoProof, reason: check.title);
    }
  });
}
