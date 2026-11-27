import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/profile_biometrics.dart';

void main() {
  testWidgets('only selected profile enables unlock; forget reloads status', (
    tester,
  ) async {
    final path = TextEditingController(text: '/private/a.db');
    final delayed = Completer<String>();
    final actions = <BiometricAction>[];
    var enrolled = true;
    final bridge = tester.binding.defaultBinaryMessenger;
    bridge.setMockMethodCallHandler(profileBiometrics, (call) async {
      if (call.method != 'status') throw UnsupportedError(call.method);
      if (call.arguments['path'] == '/private/a.db') return delayed.future;
      return enrolled ? 'enrolled' : 'available';
    });
    addTearDown(() => bridge.setMockMethodCallHandler(profileBiometrics, null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileBiometricActions(
            path: path,
            disabled: false,
            russian: false,
            perform: (action) async {
              actions.add(action);
              if (action == BiometricAction.forget) enrolled = false;
            },
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 210));
    path.text = '/private/b.db';
    await tester.pump(const Duration(milliseconds: 210));
    await tester.pumpAndSettle();
    delayed.complete('unavailable');
    await tester.pump();
    expect(find.text('Unlock with biometrics'), findsOneWidget);
    await tester.tap(find.text('Forget biometric unlock'));
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
    expect(actions, [BiometricAction.forget]);
    expect(find.text('Enable biometrics for this profile'), findsOneWidget);
    expect(find.text('Unlock with biometrics'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    path.dispose();
  });

  testWidgets(
    'unavailable enrollment offers manual recovery and scoped removal',
    (tester) async {
      final path = TextEditingController(text: '/private/a.db');
      final actions = <BiometricAction>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        profileBiometrics,
        (_) async => 'recovery',
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(profileBiometrics, null),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProfileBiometricActions(
              path: path,
              disabled: false,
              russian: false,
              perform: (action) async => actions.add(action),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 220));
      expect(find.textContaining('store passphrase'), findsOneWidget);
      expect(find.text('Unlock with biometrics'), findsNothing);
      expect(find.text('Enable biometrics for this profile'), findsNothing);
      await tester.tap(find.text('Forget biometric unlock'));
      expect(actions, [BiometricAction.forget]);
      await tester.pumpWidget(const SizedBox());
      path.dispose();
    },
  );

  testWidgets('unavailable channel offers no biometric operations', (
    tester,
  ) async {
    final path = TextEditingController(text: '/private/a.db');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      profileBiometrics,
      (call) async => throw PlatformException(code: 'unavailable'),
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        profileBiometrics,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileBiometricActions(
            path: path,
            disabled: false,
            russian: false,
            perform: (_) async => fail('unexpected'),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 210));
    await tester.pumpAndSettle();
    expect(find.byType(OutlinedButton), findsNothing);
    await tester.pumpWidget(const SizedBox());
    path.dispose();
  });
}
