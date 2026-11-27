import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/account_hub.dart';

void main() {
  testWidgets('search, pin, archive and restore survive reopening the hub', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var profile = <String, dynamic>{'trustState': 'DEVICE_TRUSTED'};

    Future<void> open() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccountHub(
              russian: false,
              profile: profile,
              crypto: (_, [args = const {}]) async =>
                  throw StateError('unexpected'),
              api: (route, {data}) async => switch (route) {
                '/v1/users/me' => {
                  'trustState': 'DEVICE_TRUSTED',
                  'userId': 'u',
                },
                '/v1/conversations' => [
                  {'id': 'a', 'peerName': 'Alice'},
                  {'id': 'b', 'peerName': 'Bob'},
                ],
                _ => [],
              },
              saveProfile: (value) async => profile = Map.of(value),
              openChat: (_, _, _, _) async => throw StateError('unexpected'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> choose(String peer, String label) async {
      final row = find.ancestor(
        of: find.text(peer),
        matching: find.byType(ListTile),
      );
      await tester.tap(
        find.descendant(of: row, matching: find.byTooltip('Chat actions')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    await open();
    await choose('Bob', 'Pin');
    expect(
      tester.getTopLeft(find.text('Bob')).dy,
      lessThan(tester.getTopLeft(find.text('Alice')).dy),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Search chats'),
      'ali',
    );
    await tester.pump();
    expect(find.text('Bob'), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, 'Search chats'), '');
    await tester.pump();
    await choose('Bob', 'Archive chat');
    await tester.pumpWidget(const SizedBox());
    await open();
    expect(find.text('Bob'), findsNothing);
    await tester.tap(find.text('Archive'));
    await tester.pump();
    expect(find.text('Alice'), findsNothing);
    await choose('Bob', 'Unarchive');
    await tester.tap(find.text('All chats'));
    await tester.pump();
    expect(find.text('Bob'), findsOneWidget);
    expect(profile['pinnedChats'], ['b']);
    await tester.pumpWidget(const SizedBox());
  });
}
