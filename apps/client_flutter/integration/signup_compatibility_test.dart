// Run with the native core (SECUREMESH_CRYPTO_LIB) and a trusted loopback TLS
// fixture (SECUREMESH_CERT_FILE and SECUREMESH_TEST_TLS_KEY).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/onboarding.dart';

class _LocalHttp extends HttpOverrides {}

void main() {
  testWidgets('signup stops after an HTML 404 from the v2 registration route', (
    tester,
  ) async {
    final env = Platform.environment;
    final context = SecurityContext()
      ..useCertificateChain(env['SECUREMESH_CERT_FILE']!)
      ..usePrivateKey(env['SECUREMESH_TEST_TLS_KEY']!);
    final original = HttpOverrides.current;
    HttpOverrides.global = _LocalHttp();
    addTearDown(() => HttpOverrides.global = original);
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const password = 'local-test-master-passphrase';
    final requests = <({String method, String path, String body})>[];
    final server = (await tester.runAsync(() async {
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      server.listen((request) async {
        requests.add((
          method: request.method,
          path: request.uri.path,
          body: await utf8.decoder.bind(request).join(),
        ));
        request.response
          ..statusCode = HttpStatus.notFound
          ..headers.contentType = ContentType.html
          ..write('<html>Route not found</html>');
        await request.response.close();
      });
      return server;
    }))!;
    addTearDown(() => server.close(force: true));

    await tester.pumpWidget(
      MaterialApp(
        home: AccountOnboarding(
          russian: false,
          defaultServer: 'https://127.0.0.1:${server.port}',
          onReady: (_, _) async => fail('Unexpected account'),
        ),
      ),
    );
    for (final field in {
      'Unique @username': 'tester_1',
      'Name on profile': 'Test User',
      'Email': 'tester@example.test',
      'Account password': password,
    }.entries) {
      final input = find.widgetWithText(TextFormField, field.key);
      await tester.ensureVisible(input);
      await tester.enterText(input, field.value);
    }
    final savedPassword = find.byType(CheckboxListTile);
    await tester.ensureVisible(savedPassword);
    await tester.tap(savedPassword);
    await tester.pump();
    final submit = find.widgetWithText(FilledButton, 'Create account');
    await tester.ensureVisible(submit);
    await tester.runAsync(() => tester.tap(submit));
    final english = find.textContaining('This server is incompatible');
    for (
      var attempt = 0;
      attempt < 250 && english.evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(english, findsOneWidget);
    expect(find.text('Email verification code'), findsNothing);
    await tester.tap(find.text('RU / EN'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Сервер несовместим'), findsOneWidget);

    final request = requests.single;
    expect(request.method, 'POST');
    expect(request.path, '/v2/auth/register');
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    expect(body['credential'], allOf(isA<String>(), isNotEmpty));
    expect(body, isNot(contains('password')));
    expect(request.body, isNot(contains(password)));
    await tester.pumpWidget(const SizedBox());
  });
}
