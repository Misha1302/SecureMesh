import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/saved_messages.dart';

void main() {
  testWidgets(
    'personal favorites page loads the next cursor and removes only the chosen message',
    (tester) async {
      final cursors = <int?>[];
      final removed = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: SavedMessages(
            tr: (_, en) => en,
            peerName: (group) => group == 'a' ? 'Анна' : 'Bob',
            read: (before) async {
              cursors.add(before);
              return {
                'messages': [
                  {
                    'id': before == null ? 'a1' : 'b1',
                    'group': before == null ? 'a' : 'b',
                    'own': false,
                    'text': before == null ? 'First saved' : 'Next saved',
                  },
                ],
                'next': before == null ? 21 : null,
              };
            },
            remove: (row) async {
              removed.add(row['id'] as String);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Анна'), findsOneWidget);
      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();
      expect(cursors, [null, 21]);
      expect(find.text('Bob'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove from saved messages').first);
      await tester.pumpAndSettle();
      expect(removed, ['a1']);
      expect(find.text('First saved'), findsNothing);
      expect(find.text('Next saved'), findsOneWidget);
    },
  );
}
