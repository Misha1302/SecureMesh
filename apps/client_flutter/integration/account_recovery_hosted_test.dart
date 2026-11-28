// Run through tests/integration/native_account_recovery.py with its disposable fixture.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/onboarding.dart';

class _LocalHttp extends HttpOverrides {}

Future<String> recoveryCode(String email) async {
  final client = HttpClient();
  try {
    final mail = Uri.http('127.0.0.1:58028', '/api/v1/search', {
      'query': 'to:$email',
    });
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      final response = await (await client.getUrl(mail)).close();
      final json =
          jsonDecode(await response.transform(utf8.decoder).join()) as Map;
      for (final row in json['messages'] as List) {
        if (!(row['Subject'] as String).toLowerCase().contains('recovery')) {
          continue;
        }
        final item = mail.replace(
          path: '/api/v1/message/${row['ID']}',
          query: '',
        );
        final message = await (await client.getUrl(item)).close();
        return (jsonDecode(await message.transform(utf8.decoder).join())['Text']
                as String)
            .trim();
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('Recovery message missing');
  } finally {
    client.close(force: true);
  }
}

void main() {
  testWidgets(
    'normal native sign-in can reset the account without opening a profile',
    (tester) async {
      final env = Platform.environment;
      final previous = HttpOverrides.current;
      HttpOverrides.global = _LocalHttp();
      addTearDown(() => HttpOverrides.global = previous);
      tester.view.physicalSize = const Size(960, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final username = env['SECUREMESH_TEST_RECOVERY_USER']!;
      final email = env['SECUREMESH_TEST_RECOVERY_EMAIL']!;
      final password = env['SECUREMESH_TEST_RECOVERY_PASSWORD']!;
      await tester.pumpWidget(
        MaterialApp(
          home: AccountOnboarding(
            russian: false,
            signIn: true,
            defaultServer: env['SECUREMESH_API_ORIGIN']!,
            onReady: (_, _) async =>
                fail('Recovery opened or created a local profile'),
          ),
        ),
      );

      Future<void> fill(String name, String content) async {
        final field = find.widgetWithText(TextFormField, name);
        await tester.ensureVisible(field);
        await tester.enterText(field, content);
      }

      Future<void> tap(String text) async {
        final button = find.text(text);
        await tester.ensureVisible(button);
        await tester.runAsync(() => tester.tap(button));
      }

      Future<void> waitFor(Finder finder) async {
        for (
          var attempt = 0;
          attempt < 300 && finder.evaluate().isEmpty;
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump(const Duration(milliseconds: 25));
        }
        expect(finder, findsOneWidget);
      }

      await tap('Forgot account password?');
      await tester.pumpAndSettle();
      await fill('Account username', username);
      await fill('Account email', email);
      await tap('Email me a recovery code');
      await waitFor(find.text('Recovery code'));
      final token = (await tester.runAsync(() => recoveryCode(email)))!;
      await fill('Recovery code', token);
      await fill('New account password', password);
      await fill('Confirm new password', password);
      await tap('Change account password');
      await waitFor(find.text('Account password changed.'));
      await tap('Back to sign-in');
      await tester.pumpAndSettle();
      expect(find.text('Sign in on this device'), findsOneWidget);
      expect(find.text(username), findsOneWidget);
      expect(find.text(password), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
