// The owning Python fixture creates disposable accounts and passes only local test credentials.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/native.dart';

class _LocalHttp extends HttpOverrides {}

void main() {
  testWidgets('Remove the open account from native Settings', (tester) async {
    final original = HttpOverrides.current;
    HttpOverrides.global = _LocalHttp();
    addTearDown(() => HttpOverrides.global = original);
    final env = Platform.environment;
    tester.view.physicalSize = const Size(1100, 1550);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Future<void> until(Finder finder) async {
      for (int i = 0; i < 500; i++) {
        if (finder.evaluate().isNotEmpty) return;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      fail('Missing control: $finder');
    }

    Future<void> hit(Finder finder) async {
      await until(finder);
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pump();
    }

    await tester.pumpWidget(const ClientApp());
    await hit(find.text('RU / EN'));
    await tester.enterText(
      find.widgetWithText(TextField, 'Store passphrase'),
      env['SECUREMESH_REMOVE_PASSPHRASE']!,
    );
    await hit(find.text('Unlock profile'));
    await hit(find.byIcon(Icons.settings_outlined));
    await hit(find.text('Advanced'));
    final deleteAccount = find.text('Delete lab account');
    await until(deleteAccount);
    await Navigator.of(tester.element(deleteAccount)).maybePop();
    await tester.pump();
    await hit(find.text('Advanced'));
    await hit(deleteAccount);
    final submit = find.widgetWithText(FilledButton, 'Delete account');
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    await tester.enterText(
      find.widgetWithText(TextField, 'Account password'),
      env['SECUREMESH_REMOVE_PASSWORD']!,
    );
    await hit(find.text('Confirm permanent removal'));
    await hit(submit);
    await until(find.text('Lab account and local profile removed.'));
    expect(File(env['SECUREMESH_PROFILE']!).existsSync(), isFalse);
    await tester.pumpWidget(const SizedBox());
  });
}
