import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/conversation_media.dart';

void main() {
  test(
    'only explicit HTTP links without credentials or hidden text are returned',
    () {
      expect(
        messageLinks(
          'Go [there](https://example.org/a_(b)). or http://test.example.',
        ).toList(),
        ['https://example.org/a_(b)', 'http://test.example'],
      );
      expect(messageLinks('|| https://example.org ||'), isEmpty);
      expect(
        messageLinks(
          'file:///private javascript:do() https://other@example.org/path',
        ),
        isEmpty,
      );
    },
  );

  testWidgets(
    'lists local media by section, pages results, and waits for explicit export',
    (tester) async {
      final requests = <Map<String, dynamic>>[];
      var downloadChecks = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationMedia(
            group: 'g',
            tr: (_, en) => en,
            crypto: (op, args) async {
              expect(op, 'conversation_media');
              requests.add(args);
              if (args['category'] == 'links') {
                return {
                  'items': [
                    {'body': 'URL https://example.org/a'},
                  ],
                  'next': null,
                };
              }
              return {
                'items': [
                  {
                    'id': 'photo',
                    'attachment': {
                      'name': args['cursor'] == null
                          ? 'first.png'
                          : 'second.png',
                      'media': 'photo',
                      'size': 25,
                    },
                  },
                ],
                'next': args['cursor'] == null ? {'opaque': true} : null,
              };
            },
            canDownload: () async {
              downloadChecks++;
              return false;
            },
            createTransfer: (_) =>
                throw StateError('revoked contact cannot download'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(requests.single, {
        'group': 'g',
        'category': 'photo',
        'cursor': null,
      });
      expect(find.text('first.png'), findsOneWidget);
      expect(downloadChecks, 0);
      await tester.tap(find.text('Show more'));
      await tester.pumpAndSettle();
      expect(find.text('second.png'), findsOneWidget);
      expect(requests.last['cursor'], {'opaque': true});
      await tester.tap(find.byTooltip('Save first.png'));
      await tester.pumpAndSettle();
      expect(downloadChecks, 1);
      expect(find.textContaining('Saving blocked'), findsOneWidget);
      await tester.tap(find.text('Links'));
      await tester.pumpAndSettle();
      expect(find.text('https://example.org/a'), findsOneWidget);
      expect(requests.last, {
        'group': 'g',
        'category': 'links',
        'cursor': null,
      });
      expect(find.byTooltip('Copy link'), findsOneWidget);
      expect(downloadChecks, 1);
    },
  );
}
