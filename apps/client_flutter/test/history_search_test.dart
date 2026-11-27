import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/history_search.dart';

void main() {
  testWidgets(
    'new input invalidates old results; private previews require a reveal',
    (tester) async {
      final first = Completer<Map<String, dynamic>>();
      final queries = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: HistorySearch(
            tr: (ru, en) => en,
            peerName: 'Alice',
            search: (q) async {
              queries.add(q);
              if (queries.length == 1) return first.future;
              return {
                'more': true,
                'messages': [
                  {
                    'id': 'A',
                    'own': false,
                    'text': '||HIDDEN TEXT||',
                    'spoiler': true,
                    'truncated': false,
                  },
                  {
                    'id': 'B',
                    'own': true,
                    'text': 'before and after the search phrase',
                    'snippet': '…after the search phrase',
                    'spoiler': false,
                    'truncated': false,
                  },
                ],
              };
            },
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'старое');
      await tester.pump();
      await tester.tap(find.byTooltip('Search'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'новое');
      await tester.pump();
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      first.complete({'more': false, 'messages': []});
      await tester.pump();
      expect(queries, ['старое', 'новое']);
      expect(find.text('No messages found'), findsNothing);
      expect(
        find.text('Showing 50 matches. Refine your search.'),
        findsOneWidget,
      );
      expect(find.text('…after the search phrase'), findsOneWidget);
      expect(find.textContaining('HIDDEN TEXT'), findsNothing);
      await tester.tap(find.text('Message with a spoiler'));
      await tester.pumpAndSettle();
      expect(find.textContaining('HIDDEN TEXT'), findsNothing);
      await tester.tap(find.text('Reveal hidden message'));
      await tester.pump();
      expect(find.text('||HIDDEN TEXT||'), findsOneWidget);
    },
  );
}
