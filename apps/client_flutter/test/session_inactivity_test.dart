import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/session_inactivity.dart';
import 'package:securemesh_client/transport.dart';

void main() {
  test(
    'activity is single flight, throttled after failures and never queued',
    () async {
      var elapsed = Duration.zero;
      final first = Completer<void>();
      final calls = <(String, String?)>[];
      final policy = SessionInactivity((
        route, {
        data,
        method,
        notFoundCode,
      }) async {
        calls.add((route, method));
        if (calls.length == 1) await first.future;
      }, elapsed: () => elapsed);

      final report = policy.recordActivity();
      elapsed += const Duration(seconds: 20);
      await policy.recordActivity();
      first.completeError(const FormatException());
      await report;
      await policy.recordActivity();
      expect(calls, [('/v1/auth/session/activity', 'POST')]);
      elapsed += const Duration(seconds: 40);
      expect(calls, hasLength(1));
      await policy.recordActivity();
      expect(calls, List.filled(2, ('/v1/auth/session/activity', 'POST')));
    },
  );

  testWidgets('only foreground pointer downs and physical key downs report', (
    tester,
  ) async {
    var activity = 0;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => SessionActivityBoundary(
          onActivity: () => activity++,
          child: child!,
        ),
        home: const Scaffold(body: TextField(autofocus: true)),
      ),
    );
    await tester.pumpAndSettle();
    expect(activity, 0);
    await tester.tap(find.byType(TextField));
    expect(activity, 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    expect(activity, 2);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.tap(find.byType(TextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    expect(activity, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(activity, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    expect(activity, 3);
  });

  testWidgets('setting changes only after server acknowledgement', (
    tester,
  ) async {
    final update = Completer<Map<String, dynamic>>();
    final calls = <(String, String?, Map<String, dynamic>?)>[];
    final policy = SessionInactivity((
      route, {
      data,
      method,
      notFoundCode,
    }) async {
      calls.add((route, method, data));
      return method == 'PUT' ? update.future : {'idleTimeout': '7'};
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionInactivityTile(policy: policy, russian: false),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('After 7 days'), findsOneWidget);
    await tester.tap(find.text('Sign out when inactive'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Never'));
    await tester.pumpAndSettle();
    expect(find.textContaining('After 7 days'), findsOneWidget);
    expect(calls, hasLength(2));
    expect(calls.first, ('/v1/auth/session/inactivity', null, null));
    expect(calls.last.$1, '/v1/auth/session/inactivity');
    expect(calls.last.$2, 'PUT');
    expect(calls.last.$3, {'idleTimeout': 'never'});
    update.complete({'idleTimeout': 'never', 'idleExpiresAt': null});
    await tester.pumpAndSettle();
    expect(find.textContaining('Never · This session only'), findsOneWidget);
  });

  testWidgets('404 hides the option and suppresses further requests', (
    tester,
  ) async {
    var requests = 0;
    final policy = SessionInactivity((
      route, {
      data,
      method,
      notFoundCode,
    }) async {
      requests++;
      throw ApiFailure(404, notFoundCode!);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionInactivityTile(policy: policy, russian: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Выход при бездействии'), findsNothing);
    await policy.recordActivity();
    expect(await policy.load(), isNull);
    expect(requests, 1);
  });
}
