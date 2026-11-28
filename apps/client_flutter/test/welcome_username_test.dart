import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/account_hub.dart';

void main() {
  for (final scenario in [
    'off-page',
    'unknown',
    'changed',
    'legacy',
    'legacy-off-page',
    'lost-ack',
  ]) {
    testWidgets('Incoming Welcome handles $scenario consent', (tester) async {
      final key = base64Encode(List.filled(32, 17));
      final mine = base64Encode(List.filled(32, 18));
      final row = {
        'id': 'invite',
        'username': 'alice',
        'senderDevice': 'device',
        'senderKey': scenario == 'changed' ? 'other' : key,
        'recipientDevice': 'mine',
        'recipientKey': mine,
        'accepted': true,
        'outgoing': false,
      };
      final calls = <String>[];
      bool accepted = ['off-page', 'changed', 'lost-ack'].contains(scenario);
      String savedName = 'alice';
      bool ackLost = false;
      String? openedName;
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
                  return scenario == 'changed' || scenario == 'legacy'
                      ? [row]
                      : [];
                }
                if (route == '/v1/chat-requests/invite') {
                  if (scenario == 'unknown') throw StateError('not found');
                  return row;
                }
                if (route.endsWith('/ack')) {
                  calls.add('ack');
                  if (scenario == 'lost-ack' && !ackLost) {
                    ackLost = true;
                    throw StateError('offline');
                  }
                }
                if (route == '/v1/crypto/welcomes') {
                  return [
                    {
                      'group': 'chat',
                      'invitation': 'invite',
                      'sender': 'device',
                      'senderKey': key,
                      'recipient': 'mine',
                    },
                  ];
                }
                return [];
              },
              crypto: (op, [args = const {}]) async {
                calls.add(op);
                if (op == 'directory_consent_status') {
                  return {
                    'accepted': accepted,
                    'sender': 'device',
                    'senderKey': key,
                    'username': savedName,
                  };
                }
                if (op == 'identity') {
                  return {'identity': 'mine', 'public_key': mine};
                }
                if (op == 'peer_key_status') return {'status': 'matches'};
                if (op == 'directory_consent') {
                  accepted = true;
                  savedName = args['username'] as String;
                }
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
      Future<void> open() async {
        await tester.ensureVisible(welcome);
        await tester.tap(welcome);
        await tester.pumpAndSettle();
      }

      await open();
      if (scenario.startsWith('legacy')) {
        await tester.tap(find.text('Verify code'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Contact’s device code'),
          key,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Confirm'));
        await tester.pumpAndSettle();
        expect(calls, contains('directory_consent'));
        expect(calls, isNot(contains('directory_join')));
        await open();
      }
      if (scenario == 'lost-ack') {
        expect(openedName, isNull);
        await open();
        expect(calls.where((op) => op == 'ack'), hasLength(2));
      }
      if (scenario == 'unknown' || scenario == 'changed') {
        expect(openedName, isNull);
        expect(calls, isNot(contains('directory_join')));
        expect(calls, isNot(contains('ack')));
      } else {
        expect(calls, containsAllInOrder(['directory_join', 'ack']));
        expect(openedName, scenario == 'legacy-off-page' ? 'Contact' : 'alice');
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
