import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/public_channels.dart';
import 'package:securemesh_client/transport.dart';

void main() {
  testWidgets(
    'Reader discovers, subscribes and reads the separate public feed',
    (tester) async {
      bool subscribed = false;
      String? search;
      Future<dynamic> api(
        String route, {
        Map<String, dynamic>? data,
        String? method,
      }) async {
        final uri = Uri.parse(route);
        if (uri.path == '/v1/public-channels') {
          search = uri.queryParameters['q'];
          return {
            'items': [
              {
                'id': 'public',
                'slug': 'demo',
                'title': 'Team news',
                'owner': false,
                'subscribed': subscribed,
              },
            ],
            'next': null,
          };
        }
        if (uri.path.endsWith('/subscription')) {
          subscribed = method == 'PUT';
          return null;
        }
        if (uri.path.endsWith('/posts') && subscribed) {
          return {
            'items': [
              {
                'seq': 1,
                'body': 'Team update',
                'publishedAt': '2026-11-01T08:00:00Z',
              },
            ],
            'next': null,
          };
        }
        throw StateError('Unexpected route $route');
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PublicChannels(api: api, russian: false, close: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('server can read'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'demo');
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      expect(search, 'demo');
      await tester.tap(find.text('Team news'));
      await tester.pumpAndSettle();
      expect(find.text('Publish'), findsNothing);
      expect(find.text('Team update'), findsNothing);
      await tester.tap(find.text('Subscribe'));
      await tester.pumpAndSettle();
      expect(find.text('Team update'), findsOneWidget);
      await tester.tap(find.text('Unsubscribe'));
      await tester.pumpAndSettle();
      expect(find.text('Team update'), findsNothing);
    },
  );

  testWidgets(
    'Owner retries a lost publication response using the same request id',
    (tester) async {
      final ids = <String>[];
      final posts = <Map>[];
      Future<dynamic> api(
        String route, {
        Map<String, dynamic>? data,
        String? method,
      }) async {
        if (Uri.parse(route).path == '/v1/public-channels') {
          if (data != null) return {'id': data['id']};
          return {'items': [], 'next': null};
        }
        if (route.endsWith('/posts')) {
          if (data == null) return {'items': posts, 'next': null};
          ids.add(data['requestId'] as String);
          if (posts.isEmpty) {
            posts.add({
              'seq': 1,
              'body': data['body'],
              'publishedAt': '2026-11-01T08:00:00Z',
            });
            throw ApiFailure(503);
          }
          return {'seq': 1};
        }
        throw StateError('Unexpected route');
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PublicChannels(api: api, russian: false, close: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('New channel'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Channel title'),
        'Bulletin',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Channel handle'),
        'bulletin',
      );
      await tester.tap(find.text('Create channel'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Public post'),
        'Hello!',
      );
      await tester.tap(find.text('Publish'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Check the connection'), findsOneWidget);
      await tester.tap(find.text('Publish'));
      await tester.pumpAndSettle();
      expect(ids.length, 2);
      expect(ids.first, ids.last);
      expect(find.text('Hello!'), findsOneWidget);
    },
  );
}
