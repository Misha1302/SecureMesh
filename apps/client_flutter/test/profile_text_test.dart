import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/profile_text.dart';
import 'package:securemesh_client/transport.dart';

void main() {
  test(
    'safe profile text supports script direction, combining marks and emoji',
    () {
      expect(
        safeProfileText('عربي 👩‍🔬\n天文', 280, multiline: true),
        'عربي 👩‍🔬\n天文',
      );
      expect(safeProfileText('a\u202eb', 80), isNull);
      expect(safeProfileText('a\nb', 80), isNull);
      expect(safeProfileText('x' * 81, 80), isNull);
      expect(safeProfileText(null, 80), isNull);
    },
  );
  testWidgets(
    'conflicting edits keep the draft until the user requests a reload',
    (tester) async {
      final saved = <Map<String, dynamic>>[];
      var read = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => ProfileTextEditor(
                    russian: false,
                    api: (route, {data, method}) async {
                      expect(route, '/v1/users/me/profile-text');
                      if (data == null) {
                        read++;
                        return {
                          'bio': read == 1 ? '旧' : '新',
                          'status': null,
                          'revision': read,
                          if (read == 1) 'visibleToPeers': true,
                        };
                      }
                      saved.add(data);
                      if (saved.length == 1) {
                        throw ApiFailure(409, 'PROFILE_CHANGED');
                      }
                      return {};
                    },
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Bio'),
        '  Зоя 👩‍🔬  ',
      );
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saved.first, {
        'bio': 'Зоя 👩‍🔬',
        'status': null,
        'revision': 1,
        'visibleToPeers': false,
      });
      expect(find.text('  Зоя 👩‍🔬  '), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Load current version'));
      await tester.pumpAndSettle();
      expect(find.text('新'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Status message'),
        'В пути',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saved.last, {'bio': '新', 'status': 'В пути', 'revision': 2});
      expect(find.text('Bio and status'), findsNothing);
    },
  );
  testWidgets('peer bio stays plain text and an unsafe status is omitted', (
    tester,
  ) async {
    int fetched = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PeerProfileText(
            russian: false,
            load: () async {
              fetched++;
              return {'bio': '<b>研究</b> 👩‍🔬', 'status': 'fake\u202e'};
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(fetched, 1);
    expect(find.text('<b>研究</b> 👩‍🔬'), findsOneWidget);
    expect(find.text('Status message'), findsNothing);
  });
}
