import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/display_name.dart';

void main() {
  test('Directory labels tolerate legacy and malformed values', () {
    expect(peerDisplayName(null), isNull);
    expect(peerDisplayName(42), isNull);
    expect(peerDisplayName(' \u202Euser'), isNull);
    expect(peerDisplayName('a' * 65), isNull);
    expect(peerDisplayName('  Люба 👩‍🔬 '), 'Люба 👩‍🔬');
  });

  testWidgets('Settings load and update the optional public label', (
    tester,
  ) async {
    final writes = <Object?>[];
    Future<dynamic> api(
      String route, {
      Map<String, dynamic>? data,
      String? method,
    }) async {
      if (route == '/v1/users/me') return {'displayName': 'Alice'};
      expect(route, '/v1/users/me/display-name');
      expect(method, 'PUT');
      writes.add(data!['displayName']);
      return data;
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => DisplayNameEditor(api: api, russian: false),
              ),
              child: const Text('Profile'),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    expect(find.text('Alice'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '  Мария  ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(writes, ['Мария']);
    expect(find.text('Display name'), findsNothing);
  });
}
