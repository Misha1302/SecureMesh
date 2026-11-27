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
}
