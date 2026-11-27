import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/settings_hierarchy.dart';

void main() {
  test(
    'appearance choices survive reopening, tolerate absent or unknown values',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'mesh-settings-test',
      );
      addTearDown(() => directory.delete(recursive: true));
      AppearancePreferences open() =>
          AppearancePreferences(directory: () async => directory);
      expect(await open().read(), (null, null));
      await open().saveTheme(ThemeMode.dark);
      await open().saveLanguage(false);
      expect(await open().read(), (ThemeMode.dark, false));
      await open().saveLanguage(true);
      expect(await open().read(), (ThemeMode.dark, true));
      await File('${directory.path}/ui-theme').writeAsString('unknown');
      expect(await open().read(), (null, true));
    },
  );

  testWidgets(
    'phone settings open one section, react to changes and return to the menu',
    (tester) async {
      tester.view.physicalSize = const Size(320, 680);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      var russian = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (_, update) => SettingsHierarchy(
                russian: russian,
                sections: SettingsSection.values,
                summary: (_) => null,
                content: (section) => [
                  if (section == SettingsSection.language)
                    ListTile(
                      title: const Text('English'),
                      onTap: () => update(() => russian = false),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('English'), findsNothing);
      await tester.drag(find.byType(ListView), const Offset(0, -480));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Язык'));
      await tester.pumpAndSettle();
      expect(find.text('Мой профиль'), findsNothing);
      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();
      expect(find.text('Language'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsNothing);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('English'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
