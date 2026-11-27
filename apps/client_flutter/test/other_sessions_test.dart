import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:securemesh_client/other_sessions.dart';

void main() {
  final rows = [
    for (final id in ['self', 'other1', 'other2', 'other3', 'old'])
      {
        'id': id,
        'isCurrent': id == 'self',
        'revoked': id == 'old',
        'hasRefreshableSession': true,
      },
  ];
  testWidgets(
    'bulk revocation excludes current/revoked and reports mixed responses after explicit confirmation',
    (tester) async {
      final called = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OtherSessionsAction(
              current: 'self',
              russian: false,
              devices: rows,
              run: (targets) => revokeListedDevices(
                targets,
                active: () => true,
                revoke: (id) async {
                  called.add(id);
                  if (id != 'other1') throw StateError('missing response');
                },
                refresh: () async => [
                  {'id': 'other2', 'revoked': true},
                  {'id': 'other3', 'revoked': false},
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('End other sessions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(called, isEmpty);
      await tester.tap(find.text('End other sessions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('End sessions'));
      await tester.pumpAndSettle();
      expect(called, ['other1', 'other2', 'other3']);
      expect(
        find.textContaining('Revocation confirmed for 2 of 3'),
        findsOneWidget,
      );
    },
  );
}
