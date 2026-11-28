import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/account_recovery.dart';
import 'package:securemesh_client/transport.dart';

void main() {
  testWidgets('recovery sends email and only the origin-bound v2 credential', (
    tester,
  ) async {
    final endpoint = Uri.parse('https://chat.example.test:8443');
    final token = List.filled(64, 'a').join();
    const newPassword = 'new recovery passphrase';
    final calls = <(String, Map<String, dynamic>?)>[];
    var accepted = false;
    await tester.pumpWidget(
      MaterialApp(
        home: AccountRecoveryPage(
          endpoint: endpoint,
          initialUsername: '@Alice_42',
          russian: false,
          request: (path, {data, token, notFoundCode}) async {
            calls.add((path, data));
            if (path.endsWith('/complete') && !accepted) {
              throw ApiFailure(400, 'INVALID_RECOVERY');
            }
          },
          derive:
              ({
                required version,
                required endpoint,
                required username,
                required password,
              }) async {
                expect(version, 2);
                expect(endpoint.origin, 'https://chat.example.test:8443');
                expect(username, 'alice_42');
                expect(password, newPassword);
                return {'credential': 'derived-test-credential'};
              },
        ),
      ),
    );
    Future<void> fill(String label, String value) async {
      final field = find.widgetWithText(TextFormField, label);
      await tester.ensureVisible(field);
      await tester.enterText(field, value);
    }

    Future<void> tap(String label) async {
      final button = find.text(label);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    await fill('Account email', 'alice@example.test');
    await tap('Email me a recovery code');
    expect(calls.single.$1, '/v1/auth/recovery/request');
    expect(calls.single.$2, {'email': 'alice@example.test'});
    await fill('Recovery code', token);
    await fill('New account password', newPassword);
    await fill('Confirm new password', 'mistyped password');
    await tap('Change account password');
    expect(find.text('The passwords do not match.'), findsOneWidget);
    expect(calls.length, 1);
    await fill('Confirm new password', newPassword);
    await tap('Change account password');
    expect(
      find.textContaining('code or username did not match'),
      findsOneWidget,
    );
    accepted = true;
    await tap('Change account password');
    expect(find.text('Account password changed.'), findsOneWidget);
    expect(find.textContaining('original profile'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    expect(calls.last.$1, '/v2/auth/recovery/complete');
    expect(calls.last.$2, {
      'username': 'alice_42',
      'token': token,
      'credential': 'derived-test-credential',
    });
    expect(calls.toString(), isNot(contains(newPassword)));
  });
}
