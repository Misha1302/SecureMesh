import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/channel_comments.dart';

void main() {
  testWidgets(
    'shows older comments and clears restricted rows after access loss',
    (tester) async {
      const path = '/channel/posts/3/comments';
      bool revoked = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChannelComments(
              path: path,
              russian: false,
              api: (route, {data, method}) async {
                if (revoked) throw StateError('membership revoked');
                if (route == '$path?before=8')
                  return {
                    'items': [
                      {
                        'id': 7,
                        'username': 'a',
                        'body': 'older',
                        'canDelete': false,
                      },
                    ],
                    'next': null,
                  };
                expect(route, path);
                return {
                  'items': [
                    {
                      'id': 8,
                      'username': 'b',
                      'body': 'newer',
                      'canDelete': true,
                    },
                  ],
                  'next': 8,
                };
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('newer'), findsOneWidget);
      await tester.tap(find.text('Older comments'));
      await tester.pumpAndSettle();
      expect(find.text('older'), findsOneWidget);
      expect(find.byTooltip('Delete comment'), findsOneWidget);
      revoked = true;
      await tester.ensureVisible(find.text('Refresh'));
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('older'), findsNothing);
      expect(find.text('newer'), findsNothing);
      expect(find.text('Could not update comments.'), findsOneWidget);
    },
  );
}
