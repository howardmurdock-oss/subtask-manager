import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orders_app/widgets/draggable_dialog.dart';

void main() {
  testWidgets('DraggableDialog renders centered and responds to drag gesture', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () {
                  DraggableDialog.show(
                    context: context,
                    title: 'Test Directive',
                    builder: (ctx, setState) {
                      return const Text('Dialog Content Inside');
                    },
                  );
                },
                child: const Text('Open Dialog'),
              );
            },
          ),
        ),
      ),
    );

    // Open dialog
    await tester.tap(find.text('Open Dialog'));
    await tester.pumpAndSettle();

    // Verify rendered
    expect(find.text('Test Directive'), findsOneWidget);
    expect(find.text('Dialog Content Inside'), findsOneWidget);

    // Drag header to reposition
    final headerFinder = find.text('Test Directive');
    final initialPos = tester.getTopLeft(headerFinder);

    await tester.drag(headerFinder, const Offset(50, 60));
    await tester.pumpAndSettle();

    final newPos = tester.getTopLeft(headerFinder);
    expect(newPos.dx, greaterThan(initialPos.dx));
    expect(newPos.dy, greaterThan(initialPos.dy));

    // Close button
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Test Directive'), findsNothing);
  });

  testWidgets('DraggableDialog prompts on backdrop tap when hasUnsavedChanges returns true', (tester) async {
    bool hasChanges = true;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () {
                  DraggableDialog.show(
                    context: context,
                    title: 'Editing Item',
                    hasUnsavedChanges: () => hasChanges,
                    builder: (ctx, setState) {
                      return const Text('Form Fields Inside');
                    },
                  );
                },
                child: const Text('Open Modal'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Modal'));
    await tester.pumpAndSettle();

    // Tap outside dialog card (top-left backdrop)
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // Verify confirmation prompt appeared
    expect(find.text('Are you sure you want to close without saving your changes?'), findsOneWidget);

    // Tap Keep Editing
    await tester.tap(find.text('Keep Editing'));
    await tester.pumpAndSettle();

    expect(find.text('Editing Item'), findsOneWidget);

    // Tap outside again and confirm Close without Saving
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Close without Saving'));
    await tester.pumpAndSettle();

    expect(find.text('Editing Item'), findsNothing);
  });
}

