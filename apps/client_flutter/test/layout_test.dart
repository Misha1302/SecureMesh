import 'package:flutter_test/flutter_test.dart';
import 'package:securemesh_client/native.dart';
import 'package:securemesh_client/onboarding.dart';
import 'package:securemesh_client/reauthentication.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/public_web.dart' as public;

void main() {
  testWidgets(
    'same-profile sign-in fits compact enlarged text; validation follows locale without sending credentials',
    (tester) async {
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileReauthentication(
            username: 'u_existing',
            onSignIn: (_, _) async {
              throw StateError('Invalid form must not send credentials');
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Войти'));
      await tester.tap(find.widgetWithText(FilledButton, 'Войти'));
      await tester.pumpAndSettle();
      expect(find.text('Введите от 12 до 256 символов.'), findsOneWidget);
      await tester.tap(find.text('RU / EN'));
      await tester.pumpAndSettle();
      expect(find.text('Enter 12–256 characters.'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .initialValue,
        'u_existing',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
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
  testWidgets('native unlock remains usable at 320 dp with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(const ClientApp());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Открыть профиль'), findsOneWidget);
    expect(find.text('Пароль хранилища'), findsOneWidget);
    await tester.ensureVisible(find.text('Создать аккаунт или войти'));
    await tester.tap(find.text('Создать аккаунт или войти'));
    await tester.pumpAndSettle();
    expect(find.text('Электронная почта'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
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
