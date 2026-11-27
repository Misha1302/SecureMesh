import 'package:flutter_test/flutter_test.dart';
import 'package:securemesh_client/native.dart';
import 'package:securemesh_client/onboarding.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/public_web.dart' as public;

void main() {
  test('account server accepts only HTTPS origins', () {
    expect(
      httpsServerOrigin(' https://chat.example.org:8443/ ')?.origin,
      'https://chat.example.org:8443',
    );
    expect(
      httpsServerOrigin('https://[::1]:5088')?.origin,
      'https://[::1]:5088',
    );
    for (final text in [
      '',
      'demo',
      'http://host',
      'https://user:pw@host',
      'https://@host',
      'https://host/path',
      'https://host?name=value',
      'https://host#fragment',
      'https://host:65536',
      'https://host:0',
      'https://host with spaces',
    ]) {
      expect(httpsServerOrigin(text), isNull, reason: text);
    }
  });

  testWidgets('operator origin visible before signup and editable', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AccountOnboarding(
          russian: false,
          defaultServer: 'https://chat.example.org:8443/',
          onReady: (_, _) async => fail('Unexpected account'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('https://chat.example.org:8443'), findsOneWidget);
    expect(find.text('HTTPS server'), findsNothing);
    await tester.tap(find.byTooltip('Change server'));
    await tester.pumpAndSettle();
    expect(find.text('HTTPS server'), findsOneWidget);
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.first, 'http://localhost');
    await tester.enterText(fields.at(3), 'broken-address');
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    final submit = find.widgetWithText(FilledButton, 'Create account');
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Enter the HTTPS server address'),
      findsOneWidget,
    );
    expect(find.textContaining('Enter an email address'), findsOneWidget);
  });
  testWidgets(
    'registration and login fit 320 dp, support EN and reject empty inputs before network',
    (tester) async {
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          home: AccountOnboarding(
            onReady: (_, _) async {
              throw StateError('Invalid input must not create a store');
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Создать аккаунт'),
            )
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Создать аккаунт'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Создать аккаунт'));
      await tester.pumpAndSettle();
      expect(find.text('Введите от 3 до 32 символов.'), findsOneWidget);
      await tester.tap(find.text('RU / EN'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('I have an account'));
      await tester.tap(find.text('I have an account'));
      await tester.pumpAndSettle();
      expect(find.text('Local store passphrase'), findsNothing);
      final legacy = find.text('Sign in to a legacy account');
      await tester.ensureVisible(legacy);
      await tester.tap(legacy);
      await tester.pumpAndSettle();
      expect(find.text('Local store passphrase'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final fields = tester.widgetList<EditableText>(find.byType(EditableText));
      expect(fields.where((field) => field.obscureText).length, 2);
      await tester.enterText(find.byType(TextFormField).at(1), 'Upper.Name');
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();
      expect(
        find.text('Use lowercase a–z, digits and underscores.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'single password counts graphemes and visibility can be toggled',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AccountOnboarding(
            russian: false,
            defaultServer: 'https://example.org',
            onReady: (_, _) async {},
          ),
        ),
      );
      final password = find.widgetWithText(TextFormField, 'Account password');
      await tester.ensureVisible(password);
      await tester.enterText(password, List.filled(15, '👩‍🔬').join());
      final reveal = find.byTooltip('Show');
      await tester.ensureVisible(reveal);
      await tester.tap(reveal);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: password,
                matching: find.byType(EditableText),
              ),
            )
            .obscureText,
        isFalse,
      );
      final save = find.byType(CheckboxListTile);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      final submit = find.widgetWithText(FilledButton, 'Create account');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(find.text('Enter 16–256 characters.'), findsOneWidget);
    },
  );
  testWidgets(
    'welcome opens registration, device sign-in and legacy unlock at 320 dp',
    (tester) async {
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(const ClientApp());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Файл профиля'), findsNothing);
      await tester.tap(find.text('Открыть сохранённый профиль'));
      await tester.pumpAndSettle();
      expect(find.text('Открыть профиль'), findsOneWidget);
      expect(find.text('Пароль хранилища'), findsOneWidget);
      await tester.ensureVisible(find.text('К выбору способа входа'));
      await tester.tap(find.text('К выбору способа входа'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Войти на этом устройстве'));
      await tester.pumpAndSettle();
      expect(find.text('Пароль локального хранилища'), findsNothing);
      expect(find.text('Электронная почта'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Создать аккаунт'));
      await tester.pumpAndSettle();
      expect(find.text('Электронная почта'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('browser explicitly gates private chat at compact width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const public.ClientApp());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.text('Приватные чаты в браузере пока недоступны'),
      findsOneWidget,
    );
  });
}
