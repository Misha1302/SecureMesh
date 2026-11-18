import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:securemesh_client/native.dart';
import 'package:securemesh_client/public_web.dart' as public;

void main() {
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
