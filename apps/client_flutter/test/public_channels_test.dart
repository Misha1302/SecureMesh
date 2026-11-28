import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/public_channels.dart';
import 'package:securemesh_client/transport.dart';

void main() {
  testWidgets(
    'Reader discovers, subscribes and reads the separate public feed',
    (tester) async {
      bool subscribed = false, revoked = false;
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
          if (revoked) throw ApiFailure(404, 'CHANNEL_NOT_FOUND');
          return {
            'pinned': {'seq': 42, 'body': 'Earlier announcement'},
            'pinRevision': 1,
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
      expect(find.text('Earlier announcement'), findsOneWidget);
      expect(find.byTooltip('Unpin'), findsNothing);
      await tester.tap(find.text('Unsubscribe'));
      await tester.pumpAndSettle();
      expect(find.text('Team update'), findsNothing);
      await tester.tap(find.text('Subscribe'));
      await tester.pumpAndSettle();
      expect(find.text('Team update'), findsOneWidget);
      revoked = true;
      await tester.tap(find.text('Refresh posts'));
      await tester.pumpAndSettle();
      expect(find.text('Team update'), findsNothing);
      expect(
        find.textContaining('This channel is unavailable'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Owner retries a lost publication response using the same request id',
    (tester) async {
      final ids = <String>[];
      final posts = <Map>[];
      int pinRevision = 0;
      Map? pin;
      Future<dynamic> api(
        String route, {
        Map<String, dynamic>? data,
        String? method,
      }) async {
        if (Uri.parse(route).path == '/v1/public-channels') {
          if (data != null) return {'id': data['id']};
          return {'items': [], 'next': null};
        }
        if (route.endsWith('/pin')) {
          expect(method, 'PUT');
          expect(data!['expectedRevision'], pinRevision++);
          pin = data['seq'] == null ? null : posts.single;
          return null;
        }
        if (route.endsWith('/posts')) {
          if (data == null) {
            return {
              'items': posts,
              'next': null,
              'pinned': pin,
              'pinRevision': pinRevision,
            };
          }
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
      await tester.ensureVisible(find.byTooltip('Post actions'));
      await tester.tap(find.byTooltip('Post actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin post'));
      await tester.pumpAndSettle();
      expect(find.text('Pinned post'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('Unpin'));
      await tester.tap(find.byTooltip('Unpin'));
      await tester.pumpAndSettle();
      expect(pinRevision, 2);
      expect(find.text('Pinned post'), findsNothing);
    },
  );
}
