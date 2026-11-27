import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/earlier_history.dart';

void main() {
  testWidgets(
    'older pages can retry a failed read and return to the previous page',
    (tester) async {
      final seen = <int>[];
      bool failNext = true;
      await tester.pumpWidget(
        MaterialApp(
          home: EarlierHistory(
            initial: const {'start': 1},
            peer: 'Contact',
            tr: (_, en) => en,
            read: (cursor) async {
              final page = cursor['start'] as int;
              seen.add(page);
              if (page == 2 && failNext) {
                failNext = false;
                throw StateError('unavailable');
              }
              return {
                'messages': [
                  {'own': false, 'text': 'history $page'},
                ],
                'next': page == 1 ? {'start': 2} : null,
              };
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('history 1'), findsOneWidget);
      await tester.tap(find.text('Older'));
      await tester.pumpAndSettle();
      expect(find.text('history 1'), findsNothing);
      await tester.tap(find.text('Retry loading'));
      await tester.pumpAndSettle();
      expect(find.text('history 2'), findsOneWidget);
      await tester.tap(find.text('Newer'));
      await tester.pumpAndSettle();
      expect(seen, [1, 2, 2, 1]);
      expect(find.text('history 1'), findsOneWidget);
    },
  );
}
