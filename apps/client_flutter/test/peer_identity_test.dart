import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/account_hub.dart';

void main() {
  for (final scenario in ['matching', 'renamed', 'new', 'changed', 'swapped']) {
    testWidgets('opening a chat with $scenario identity', (tester) async {
      var opened = false;
      final calls = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccountHub(
              russian: false,
              profile: {
                'trustState': 'DEVICE_TRUSTED',
                if (scenario != 'new')
                  'verifiedChats': {
                    'chat': {'device': 'device', 'key': 'key', 'name': 'alice'},
                  },
              },
              api: (route, {data}) async {
                if (route == '/v1/users/me') {
                  return {'trustState': 'DEVICE_TRUSTED'};
                }
                if (route == '/v1/conversations') {
                  return [
                    {
                      'id': 'chat',
                      'peerDevice': scenario == 'swapped'
                          ? 'other-device'
                          : 'device',
                      'peerKey': 'key',
                      'peerName': scenario == 'renamed' ? 'bob' : 'alice',
                    },
                  ];
                }
                return [];
              },
              crypto: (op, [args = const {}]) async {
                calls.add(op);
                if (op == 'identity') return {'public_key': 'own-key'};
                if (op == 'peer_key_status') {
                  return {
                    'status': switch (scenario) {
                      'new' => 'unknown',
                      'changed' => 'changed',
                      _ => 'matches',
                    },
                  };
                }
                throw StateError('Unexpected crypto operation $op');
              },
              openChat: (_, _, _, _) async => opened = true,
              saveProfile: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(scenario == 'renamed' ? 'bob' : 'alice'));
      await tester.pumpAndSettle();
      expect(opened, scenario == 'matching');
      if (scenario == 'renamed' || scenario == 'new') {
        expect(find.text('Compare device keys'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Confirm'),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      } else if (scenario != 'matching') {
        expect(find.textContaining('This chat is blocked.'), findsOneWidget);
      }
      expect(calls, isNot(contains('pin')));
      await tester.pumpWidget(const SizedBox());
    });
  }
}
