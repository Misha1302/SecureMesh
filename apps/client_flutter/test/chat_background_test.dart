import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:securemesh_client/chat_background.dart';

void main() {
  testWidgets(
    'appearance screen edits the active chat and can restore inheritance',
    (tester) async {
      final profile = <String, dynamic>{'chatBackground': 'blue'};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => ChatBackgroundSettings(
                profile: profile,
                group: 'a',
                name: 'alice',
                tr: (_, en) => en,
                save: (group, dark, color) => setState(() {
                  profile['chatBackgrounds'] = updateChatBackground(
                    profile,
                    group,
                    dark,
                    color,
                  );
                }),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Mint').last);
      await tester.pumpAndSettle();
      expect(chatBackground(profile, 'a', false), 'mint');
      expect(chatBackground(profile, 'b', false), 'blue');
      await tester.tap(find.text('Use global setting'));
      await tester.pumpAndSettle();
      expect(chatBackground(profile, 'a', false), 'blue');
    },
  );

  test('legacy background is inherited until explicitly overridden', () {
    final profile = <String, dynamic>{'chatBackground': 'blue'};
    expect(chatBackground(profile, 'a', false), 'blue');
    profile['chatBackgrounds'] = updateChatBackground(
      profile,
      null,
      true,
      'mint',
    );
    expect(chatBackground(profile, 'a', true), 'mint');
    expect(chatBackground(profile, 'a', false), 'blue');
  });

  test('overrides and reset are isolated per chat and theme', () {
    final profile = <String, dynamic>{};
    void save(String? group, bool dark, String? color) {
      profile['chatBackgrounds'] = updateChatBackground(
        profile,
        group,
        dark,
        color,
      );
    }

    save(null, false, 'mint');
    save('a', false, 'default');
    save('b', true, 'blue');
    expect(chatBackground(profile, 'a', false), 'default');
    expect(chatBackground(profile, 'b', false), 'mint');
    expect(chatBackground(profile, 'b', true), 'blue');
    save('a', false, null);
    expect(chatBackground(profile, 'a', false), 'mint');
    expect(chatBackground(profile, 'b', true), 'blue');
  });
}
