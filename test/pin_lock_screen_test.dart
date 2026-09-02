import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/core/security/security_service.dart';
import 'package:orders_app/views/security/pin_lock_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('PinLockScreen renders with high-contrast buttons and accepts digits', (tester) async {
    final security = SecurityService();
    await security.init();
    await security.setPin('1234');
    security.lockApp();
    expect(security.isUnlocked, isFalse);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: security,
        child: const MaterialApp(
          home: PinLockScreen(),
        ),
      ),
    );

    // Verify digits 0-9 and header are present
    expect(find.text('SECURITY LOCK'), findsOneWidget);
    for (int i = 0; i <= 9; i++) {
      expect(find.text('$i'), findsOneWidget);
    }
    expect(find.byIcon(Icons.backspace_outlined), findsOneWidget);

    // Tap digits 1, 2, 3, 4
    await tester.tap(find.text('1'));
    await tester.pump();
    await tester.tap(find.text('2'));
    await tester.pump();
    await tester.tap(find.text('3'));
    await tester.pump();
    await tester.tap(find.text('4'));
    await tester.pumpAndSettle();

    // Verify PIN unlocked
    expect(security.isUnlocked, isTrue);
  });
}
