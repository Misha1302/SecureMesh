import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:securemesh_client/security_email_tile.dart';

void main() {
  testWidgets(
    'trusted preference loads, saves, and re-reads after uncertain writes',
    (tester) async {
      var stored = false, fail = false, reads = 0, writes = 0;
      final loading = Completer<void>();
      Future<dynamic> request(
        String path, {
        Map<String, dynamic>? data,
        String? method,
      }) async {
        expect(path, '/v1/users/me/security-email');
        if (method == 'PUT') {
          writes++;
          stored = data!['enabled'] as bool;
          if (fail) throw StateError('lost response');
        } else {
          reads++;
          await loading.future;
        }
        return {'enabled': stored};
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SecurityEmailTile(russian: false, request: request),
          ),
        ),
      );
      expect(find.text('Loading…'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
      loading.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, false);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(stored, true);
      fail = true;
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('Could not check this setting.'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, false);
      expect((reads, writes), (2, 2));
    },
  );
}
