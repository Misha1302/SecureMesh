import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/account_hub.dart';
import 'package:securemesh_client/identity_comparison.dart';

void main() {
  final ownKey = base64Encode(List.filled(32, 7));
  final peerKey = base64Encode(List.filled(32, 3));
  for (final scenario in [
    'verified',
    'unknown',
    'native-change',
    'directory-change',
  ]) {
    testWidgets('profile verification with $scenario identity', (tester) async {
      final calls = <String>[];
      var profile = <String, dynamic>{
        'trustState': 'DEVICE_TRUSTED',
        if (scenario != 'unknown')
          'verifiedChats': {
            'group': {
              'name': 'alice',
              'device': scenario == 'directory-change' ? 'old' : 'device',
              'key': peerKey,
            },
          },
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccountHub(
              profile: profile,
              russian: false,
              crypto: (op, [args = const {}]) async {
                calls.add(op);
                return switch (op) {
                  'conversation_previews' => {'previews': {}},
                  'conversation_media' => {'items': [], 'next': null},
                  'peer_key_status' => {
                    'status': switch (scenario) {
                      'unknown' => 'unknown',
                      'native-change' => 'changed',
                      _ => 'matches',
                    },
                  },
                  'identity' => {'public_key': ownKey},
                  'pin' => {'saved': true},
                  _ => throw StateError(op),
                };
              },
              api: (route, {data}) async => switch (route) {
                '/v1/users/me' => {
                  'trustState': 'DEVICE_TRUSTED',
                  'userId': 'me',
                },
                '/v1/conversations' => [
                  {
                    'id': 'group',
                    'peerDevice': 'device',
                    'peerName': 'alice',
                    'peerDisplayName': 'Алиса',
                    'peerKey': peerKey,
                  },
                ],
                _ => [],
              },
              saveProfile: (saved) async => profile = Map.of(saved),
              openChat: (_, _, _, _) async =>
                  throw StateError('Profile cannot open or send'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Profile · Алиса'));
      await tester.pumpAndSettle();
      expect(find.text('Contact profile'), findsOneWidget);
      if (scenario != 'verified') {
        expect(find.text('Shared media'), findsNothing);
      }
      if (scenario.endsWith('change')) {
        expect(find.textContaining('This chat is blocked.'), findsOneWidget);
        expect(find.text('Verify identity'), findsNothing);
        expect(find.text('Compare again'), findsNothing);
        expect(find.text(deviceFingerprint(peerKey)!), findsNothing);
      } else {
        if (scenario == 'verified') {
          await tester.tap(find.text('Shared media'));
          await tester.pumpAndSettle();
          expect(
            find.text('No items in this section on this device.'),
            findsOneWidget,
          );
          expect(calls, contains('conversation_media'));
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(find.text(deviceFingerprint(peerKey)!), findsOneWidget);
          await tester.tap(find.text('Compare again'));
        } else {
          expect(find.text(deviceFingerprint(peerKey)!), findsNothing);
          await tester.tap(find.text('Verify identity'));
        }
        await tester.pumpAndSettle();
        final confirm = find.widgetWithText(FilledButton, 'Confirm');
        expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
        await tester.enterText(
          find.widgetWithText(TextField, 'Contact’s device code'),
          deviceFingerprint(peerKey)!,
        );
        await tester.pump();
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(calls, contains('pin'));
        expect(profile['verifiedChats']['group']['device'], 'device');
      }
      if (scenario.endsWith('change')) expect(calls, isNot(contains('pin')));
      await tester.pumpWidget(const SizedBox());
    });
  }
}
