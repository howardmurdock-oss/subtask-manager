import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:orders_app/core/security/security_service.dart';
import 'package:orders_app/views/disguise/panic_decoy_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('PanicDecoyView renders with help icon and unlock prompt', (tester) async {
    final securityService = SecurityService();
    await securityService.init();

    await tester.pumpWidget(
      ChangeNotifierProvider<SecurityService>.value(
        value: securityService,
        child: const MaterialApp(
          home: PanicDecoyView(),
        ),
      ),
    );

    expect(find.text('Calculator'), findsOneWidget);
    expect(find.byIcon(Icons.help_outline_rounded), findsOneWidget);

    // Tap the '?' help button
    await tester.tap(find.byIcon(Icons.help_outline_rounded));
    await tester.pumpAndSettle();

    // Verify dialog pops up with exit instructions
    expect(find.text('Calculator Decoy'), findsOneWidget);
    expect(find.text('Enter 7777 = to exit and return to the main application.'), findsOneWidget);

    // Dismiss dialog
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Calculator Decoy'), findsNothing);

    // Test secret unlock sequence 7777 =
    await tester.tap(find.widgetWithText(ElevatedButton, '7'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ElevatedButton, '7'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ElevatedButton, '7'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ElevatedButton, '7'));
    await tester.pump();

    expect(find.text('7777'), findsOneWidget);

    // Trigger panic mode to test exit
    securityService.triggerPanic();
    expect(securityService.isPanicModeActive, isTrue);

    await tester.tap(find.widgetWithText(ElevatedButton, '='));
    await tester.pump();

    // Verify panic mode exited
    expect(securityService.isPanicModeActive, isFalse);
  });
}
