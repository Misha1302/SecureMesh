import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/linked_roster.dart';

void main() {
  testWidgets('account trust cannot substitute for conversation consent', (
    tester,
  ) async {
    bool? consent;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                consent = await confirmRosterChange(
                  context,
                  group: 'conversation-id',
                  description: 'add device-id key',
                  tr: (_, en) => en,
                );
              },
              child: const Text('Enroll'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Enroll'));
    await tester.pumpAndSettle();
    expect(find.text('conversation-id'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(consent, false);
    await tester.tap(find.text('Enroll'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(consent, true);
  });
}
