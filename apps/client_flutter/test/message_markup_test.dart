import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/message_markup.dart';

String english(String ru, String en) => en;

void main() {
  test('format preserves selection and numbers multiline selections', () {
    final controller = TextEditingController(text: 'one\ntwo');
    addTearDown(controller.dispose);
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 7);
    formatMessage(controller, MessageFormat.numbers);
    expect(controller.text, '1. one\n2. two');
    controller.selection = const TextSelection(baseOffset: 3, extentOffset: 6);
    formatMessage(controller, MessageFormat.bold);
    expect(controller.text, '1. **one**\n2. two');
    expect(controller.selection.textInside(controller.text), 'one');
  });

  test('formatting does not bypass the composer length limit', () {
    final controller = TextEditingController(
      text: List.filled(4000, 'x').join(),
    );
    addTearDown(controller.dispose);
    formatMessage(controller, MessageFormat.spoiler);
    expect(controller.text, List.filled(4000, 'x').join());
  });

  testWidgets(
    'desktop shortcut and toolbar format the selected composer text',
    (tester) async {
      final controller = TextEditingController(text: 'word');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageComposer(
              controller: controller,
              tr: english,
              onSubmitted: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 4,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(controller.text, '**word**');
      await tester.tap(find.byTooltip('Formatting'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Spoiler'));
      await tester.pumpAndSettle();
      expect(controller.text, '**||word||**');
    },
  );

  testWidgets('links are inspectable, spoilers hidden, HTML is literal text', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageMarkup(
            '<img src="https://example.org/pixel">\n[Open](https://example.org/path)\n||hidden||\n[bad](javascript:noop)',
            tr: english,
          ),
        ),
      ),
    );
    expect(find.byType(Image), findsNothing);
    expect(
      find.text('<img src="https://example.org/pixel">', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.text('[bad](javascript:noop)', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('hidden'), findsNothing);
    await tester.tap(find.text('Reveal spoiler'));
    await tester.pump();
    expect(find.text('hidden'), findsOneWidget);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Link address'), findsOneWidget);
    expect(find.text('https://example.org/path'), findsOneWidget);
  });

  testWidgets('fenced code stays literal and has a copy action', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageMarkup(
            '```dart\nfinal x = "**literal**";\n```',
            tr: english,
          ),
        ),
      ),
    );
    expect(find.byTooltip('Copy code'), findsOneWidget);
    expect(
      find.text('final x = "**literal**";', findRichText: true),
      findsOneWidget,
    );
    expect(find.byType(ActionChip), findsNothing);
  });
}
