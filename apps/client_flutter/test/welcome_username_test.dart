import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/account_hub.dart';

void main() {
  for (final matchingKey in [true, false]) {
    testWidgets('Welcome matches invite key: $matchingKey', (tester) async {
      String? openedName;
      final calls = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccountHub(
              russian: false,
              profile: {'trustState': 'DEVICE_TRUSTED'},
              api: (route, {data}) async {
                if (route == '/v1/users/me') {
                  return {'trustState': 'DEVICE_TRUSTED'};
                }
                if (route == '/v1/chat-requests') {
                  return [
                    {
                      'id': 'invite',
                      'username': 'alice',
                      'senderDevice': 'device',
                      'senderKey': matchingKey ? 'key' : 'other',
                      'accepted': true,
                      'outgoing': false,
                    },
                  ];
                }
                if (route == '/v1/crypto/welcomes') {
                  return [
                    {
                      'group': 'chat',
                      'invitation': 'invite',
                      'sender': 'device',
                      'senderKey': 'key',
                    },
                  ];
                }
                return [];
              },
              crypto: (op, [args = const {}]) async {
                calls.add(op);
                if (op == 'peer_key_status') return {'status': 'matches'};
                if (op == 'identity') return {'public_key': 'mine'};
                return {};
              },
              openChat: (_, _, name, _) async => openedName = name,
              saveProfile: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final welcome = find.text('Secure conversation is ready');
      await tester.ensureVisible(welcome);
      await tester.tap(welcome);
      await tester.pumpAndSettle();
      expect(openedName, isNull);
      if (!matchingKey) {
        expect(find.text('Chat blocked'), findsOneWidget);
        expect(calls, isEmpty);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        return;
      }
      await tester.tap(find.text('I compared these keys'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(
        calls,
        containsAllInOrder([
          'peer_key_status',
          'identity',
          'pin',
          'directory_join',
        ]),
      );
      expect(openedName, 'alice');
      await tester.pumpWidget(const SizedBox());
    });
  }
}
