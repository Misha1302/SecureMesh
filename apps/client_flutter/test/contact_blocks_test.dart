import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/contact_blocks.dart';

void main() {
  testWidgets('block and unblock accounts using the signed-in directory API', (
    tester,
  ) async {
    final requests = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showContactBlocks(
              context,
              username: 'alice',
              tr: (_, en) => en,
              api: (path, {data, method}) async {
                requests.add('${method ?? 'GET'} $path');
                return method == null ? {'items': <String>[]} : null;
              },
            ),
            child: const Text('Open blocked accounts'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open blocked accounts'));
    await tester.pumpAndSettle();
    expect(find.text('alice'), findsOneWidget);
    await tester.tap(find.text('Block invitations'));
    await tester.pumpAndSettle();
    expect(find.text('@alice'), findsOneWidget);
    await tester.tap(find.text('Unblock'));
    await tester.pumpAndSettle();
    expect(find.text('@alice'), findsNothing);
    expect(requests, [
      'GET /v1/contact-blocks',
      'PUT /v1/contact-blocks/alice',
      'DELETE /v1/contact-blocks/alice',
    ]);
  });
}
