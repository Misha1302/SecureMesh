import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/native.dart';

void main() {
  testWidgets(
    'compact chat preserves timeline space and exposes every action',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      const name = 'u_3e2450f8489842ec9ad4';
      final actions = <String>[];

      Future<void> render({required bool verified}) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ConversationHeader(
                  peerName: name,
                  verified: verified,
                  canCall: verified,
                  tr: (ru, en) => ru,
                  onBack: () => actions.add('back'),
                  onCall: (video) => actions.add(video ? 'video' : 'audio'),
                  onSearch: () => actions.add('search'),
                  onVerify: () => actions.add('verify'),
                ),
                const Expanded(child: Placeholder()),
              ],
            ),
          ),
        ),
      );

      await render(verified: true);
      expect(
        tester.getSize(find.byType(ConversationHeader)).height,
        lessThan(105),
      );
      expect(tester.widget<Text>(find.text(name)).maxLines, 1);
      expect(find.text('Ключи проверены'), findsOneWidget);
      await tester.tap(find.byTooltip('Все чаты'));
      for (final label in [
        'Поиск в переписке',
        'Аудиозвонок',
        'Видеозвонок',
        'Проверить ключи',
      ]) {
        await tester.tap(find.byTooltip('Действия чата'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }
      expect(actions, ['back', 'search', 'audio', 'video', 'verify']);

      await render(verified: false);
      await tester.tap(find.byTooltip('Действия чата'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Аудиозвонок'));
      await tester.pumpAndSettle();
      expect(actions.length, 5);
      expect(find.text('Проверить ключи'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
