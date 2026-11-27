import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/device_tile.dart';

void main() {
  testWidgets(
    'remote revocation requires confirmation for the displayed device',
    (tester) async {
      int calls = 0;
      Future<void> show({bool current = false, bool revoked = false}) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DeviceTile(
                device: {
                  'id': 'device-two',
                  'revoked': revoked,
                  'trustState': 'DEVICE_PENDING_TRUST',
                },
                current: current,
                russian: false,
                onRevoke: () => calls++,
              ),
            ),
          ),
        );
      }

      await show();
      expect(find.text('Awaiting approval'), findsOneWidget);
      await tester.tap(find.byTooltip('Revoke access'));
      await tester.pumpAndSettle();
      expect(find.text('device-two'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      await tester.tap(find.byTooltip('Revoke access'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revoke'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      await show(current: true);
      expect(find.byTooltip('Revoke access'), findsNothing);
      await show(revoked: true);
      expect(find.text('Revoked'), findsOneWidget);
      expect(find.byTooltip('Revoke access'), findsNothing);
    },
  );
  testWidgets(
    'current OS and user label are distinct from trust and the device identifier',
    (tester) async {
      String? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DeviceTile(
              device: {
                'id': 'opaque-id',
                'name': 'Ноутбук',
                'clientOs': 'windows',
                'createdAt': '2026-11-26T08:00:00Z',
                'lastLoginAt': '2026-11-27T08:33:00Z',
                'hasRefreshableSession': true,
                'trustState': 'DEVICE_TRUSTED',
              },
              current: true,
              localOs: 'linux',
              russian: false,
              onRevoke: null,
              onRename: (name) async {
                saved = name;
              },
            ),
          ),
        ),
      );
      expect(find.text('Ноутбук'), findsOneWidget);
      expect(find.byIcon(Icons.computer), findsOneWidget);
      expect(find.text('This device'), findsOneWidget);
      expect(find.text('opaque-id'), findsNothing);
      await tester.tap(find.text('Ноутбук'));
      await tester.pumpAndSettle();
      expect(find.text('App-reported OS: Linux'), findsOneWidget);
      expect(find.text('Has a valid session'), findsOneWidget);
      expect(find.textContaining('Last password sign-in:'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Rename device'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Рабочий компьютер');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saved, 'Рабочий компьютер');
    },
  );

  testWidgets(
    'remote labels reject control characters and use recognized OS only',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DeviceTile(
              device: {
                'id': 'remote-test-id',
                'name': 'Work\u202Eevil',
                'clientOs': 'android',
                'trustState': 'DEVICE_TRUSTED',
              },
              current: false,
              russian: false,
              onRevoke: () {},
            ),
          ),
        ),
      );
      expect(find.text('Android'), findsOneWidget);
      expect(find.byIcon(Icons.android), findsOneWidget);
      expect(find.text('Other device'), findsOneWidget);
      expect(find.textContaining('evil'), findsNothing);
      expect(find.byTooltip('Rename device'), findsNothing);
    },
  );
}
