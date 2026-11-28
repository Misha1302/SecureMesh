import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/account_hub.dart';

void main() {
  testWidgets(
    'mobile inbox shows only local previews with matching identities',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final chats = [
        for (final name in ['bob', 'alice', 'eve'])
          {'id': name, 'peerName': name, 'peerKey': name, 'peerDevice': name},
      ];
      final profile = {
        'trustState': 'DEVICE_TRUSTED',
        'group': 'bob',
        'verifiedChats': {
          for (final name in ['bob', 'alice', 'eve'])
            name: {
              'name': name,
              'key': name == 'eve' ? 'old' : name,
              'device': name,
            },
        },
      };
      final calls = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccountHub(
              russian: false,
              profile: profile,
              crypto: (op, [args = const {}]) async {
                calls.add(op);
                return {
                  'previews': {
                    for (final (i, name) in ['bob', 'alice', 'eve'].indexed)
                      name: {
                        'text': [
                          'hello',
                          'hidden ||spoiler||',
                          'wrong identity',
                        ][i],
                        'own': i == 0,
                        'localTimeMs': 1000000000 + i * 40,
                        'unread': i,
                      },
                  },
                };
              },
              api: (route, {data}) async => switch (route) {
                '/v1/users/me' => {
                  'trustState': 'DEVICE_TRUSTED',
                  'userId': 'me',
                },
                '/v1/conversations' => chats,
                _ => [],
              },
              saveProfile: (_) async {},
              openChat: (_, _, _, _) async => throw StateError('unexpected'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, ['conversation_previews']);
      expect(find.text('You: hello'), findsOneWidget);
      expect(find.text('Message with a spoiler'), findsOneWidget);
      expect(find.textContaining('hidden'), findsNothing);
      expect(find.text('wrong identity'), findsNothing);
      expect(find.text('@eve'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('Unread messages: 1')),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(find.text('alice')).dy,
        lessThan(tester.getTopLeft(find.text('bob')).dy),
      );
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('chat-bob')))
            .selected,
        isTrue,
      );
      expect(find.text('Verify device'), findsNothing);
      await tester.tap(find.text('Link devices'));
      await tester.pumpAndSettle();
      expect(find.text('Verify device'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('block hides avatar through failed refresh and unblock', (
    tester,
  ) async {
    const group = '00000000-0000-0000-0000-000000000001';
    const version = '00000000-0000-0000-0000-000000000002';
    var blocked = false;
    var directoryReads = 0;
    var failRefresh = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountHub(
            russian: false,
            profile: {'trustState': 'DEVICE_TRUSTED'},
            crypto: (_, [args = const {}]) async => {},
            api: (route, {data}) async {
              if (route == '/v1/users/me')
                return {'trustState': 'DEVICE_TRUSTED', 'userId': 'me'};
              if (route == '/v1/conversations') {
                directoryReads++;
                if (failRefresh) throw StateError('offline');
                return [
                  {
                    'id': group,
                    'peerName': 'alice',
                    'peerKey': 'key',
                    'peerDevice': 'device',
                    'peerPhotoVersion': blocked ? null : version,
                  },
                ];
              }
              if (route == '/v1/chat-requests')
                return blocked
                    ? []
                    : [
                        {
                          'id': 'request',
                          'username': 'alice',
                          'outgoing': false,
                          'accepted': false,
                        },
                      ];
              if (route.contains('/photo/'))
                return {'pixels': base64Encode(Uint8List(6912))};
              return [];
            },
            channelApi: (route, {data, method}) async {
              if (method == 'PUT') {
                blocked = true;
                failRefresh = true;
                return null;
              }
              if (method == 'DELETE') {
                blocked = false;
                return null;
              }
              return {'items': <String>[]};
            },
            saveProfile: (_) async {},
            openChat: (_, _, _, _) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CircleAvatar>(find.byType(CircleAvatar).first)
          .foregroundImage,
      isNotNull,
    );
    await tester.ensureVisible(find.byTooltip('Block invitations'));
    await tester.tap(find.byTooltip('Block invitations'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Block invitations').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CircleAvatar>(find.byType(CircleAvatar).first)
          .foregroundImage,
      isNull,
    );
    await tester.tap(find.text('Unblock'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CircleAvatar>(find.byType(CircleAvatar).first)
          .foregroundImage,
      isNull,
    );
    await tester.tap(find.text('Close').last);
    await tester.pumpAndSettle();
    expect(directoryReads, greaterThanOrEqualTo(2));
    expect(
      tester
          .widget<CircleAvatar>(find.byType(CircleAvatar).first)
          .foregroundImage,
      isNull,
    );
    expect(find.byKey(const ValueKey('chat-$group')), findsOneWidget);
    failRefresh = false;
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CircleAvatar>(find.byType(CircleAvatar).first)
          .foregroundImage,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'new chat submits a normalized username through the existing request protocol',
    (tester) async {
      final writes = <Map<String, dynamic>>[];
      final patches = <Map<String, dynamic>>[];
      final removals = <Set<String>>[];
      final me = Completer<Map>();
      Future<void> build(String active) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AccountHub(
                russian: false,
                profile: {'trustState': 'DEVICE_TRUSTED', 'group': active},
                crypto: (_, [args = const {}]) async => {},
                api: (route, {data}) async {
                  if (route == '/v1/users/me') return me.future;
                  if (route == '/v1/chat-requests' && data != null) {
                    writes.add(data);
                  }
                  return [];
                },
                saveProfile: (_) async => throw StateError('expected delta'),
                saveChanges: (change, removed) async {
                  patches.add(change);
                  removals.add(removed);
                },
                openChat: (_, _, _, _) async {},
              ),
            ),
          ),
        );
      }

      await build('old-chat');
      await build('new-chat');
      me.complete({'trustState': 'DEVICE_TRUSTED', 'userId': 'me'});
      await tester.pumpAndSettle();
      expect(patches.single, {'userId': 'me'});
      await tester.tap(find.byTooltip('New chat'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Contact username'),
        '@ALICE',
      );
      await tester.tap(find.text('Send chat request'));
      await tester.pumpAndSettle();
      expect(writes.single['username'], 'alice');
      expect(writes.single['id'], isA<String>());
      expect(patches.any((patch) => patch.containsKey('group')), isFalse);
      expect(removals.last, {'outgoingRequest'});
      expect(find.widgetWithText(TextField, 'Contact username'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
