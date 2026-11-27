import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/conversation_composer.dart';
import 'package:securemesh_client/conversation_timeline.dart';
import 'package:securemesh_client/message_markup.dart';

String en(String ru, String en) => en;

Map<String, dynamic> message(int i, {DateTime? time, bool own = false}) => {
  'id': 'id$i',
  'sender': own ? 'me' : 'peer',
  'own': own,
  'text': 'message $i',
  'status': own ? 'delivered' : 'received',
  if (time != null) 'localTimeMs': time.millisecondsSinceEpoch,
};

void main() {
  testWidgets('local day groups, delivery evidence, reply and selection', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final first = DateTime(2026, 11, 26, 13, 21);
    final second = DateTime(2026, 11, 27, 9, 42);
    final rows = [
      message(0),
      message(1, time: first),
      message(2, time: first, own: true),
      message(3, time: second),
    ];
    String? replied;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationTimeline(
            tr: en,
            scroll: scroll,
            messages: rows,
            replyPreview: (_, _) => '',
            attachment: (_, _, _) => const SizedBox(),
            onReply: (id, _) => replied = id,
          ),
        ),
      ),
    );
    final context = tester.element(find.byType(ConversationTimeline));
    final fmt = MaterialLocalizations.of(context);
    expect(find.text(fmt.formatMediumDate(first)), findsOneWidget);
    expect(find.text(fmt.formatMediumDate(second)), findsOneWidget);
    expect(
      find.text(fmt.formatTimeOfDay(TimeOfDay.fromDateTime(first))),
      findsNWidgets(2),
    );
    expect(find.byIcon(Icons.done_all), findsOneWidget);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.done_all)).semanticLabel,
      'Delivery reported by server',
    );
    await tester.tap(find.byTooltip('Message actions').at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();
    expect(replied, 'id1');
    await tester.tap(find.byTooltip('Message actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Message actions').at(2));
    await tester.pumpAndSettle();
    expect(find.text('Selected: 2'), findsOneWidget);
    String? copied;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = call.arguments['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.tap(find.byTooltip('Copy selected text'));
    await tester.pumpAndSettle();
    expect(copied, 'message 0\nmessage 2');
    expect(find.text('Selected: 2'), findsNothing);
  });

  testWidgets(
    'new incoming messages preserve the reader position and supply a jump target',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final rows = List.generate(46, (i) => message(i));
      Future<void> render(List<dynamic> messages) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConversationTimeline(
              tr: en,
              messages: messages,
              scroll: scroll,
              onReply: null,
              replyPreview: (_, _) => '',
              attachment: (_, _, _) => const SizedBox(),
            ),
          ),
        ),
      );
      await render(rows);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -310));
      await tester.pumpAndSettle();
      final previous = scroll.offset;
      await render([...rows, message(46), message(47)]);
      await tester.pumpAndSettle();
      expect(scroll.offset, previous);
      await tester.tap(find.text('First new'));
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(previous));
      expect(find.text('message 46').hitTestable(), findsOneWidget);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 500));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Latest message'));
      await tester.pumpAndSettle();
      expect(find.text('message 47').hitTestable(), findsOneWidget);
    },
  );

  testWidgets(
    '320dp leaves room for multiline input, attachment actions and keyboard send',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final actions = <String>[];
      Future<void> render() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ConversationComposer(
                tr: en,
                onSend: () => actions.add('send'),
                onFile: () => actions.add('file'),
                onVoice: () => actions.add('voice'),
                onVideo: () => actions.add('video'),
                videoSupported: true,
                editor: MessageComposer(
                  controller: controller,
                  tr: en,
                  onSubmitted: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await render();
      final field = find.byType(TextField);
      expect(tester.getSize(field).width, greaterThan(235));
      for (final name in [
        'Attach file (up to 4 MiB)',
        'Record a voice note',
        'Record video message',
      ]) {
        await tester.tap(find.byTooltip(name));
      }
      await tester.enterText(field, 'line one\nline two');
      expect(controller.text, 'line one\nline two');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(actions, ['file', 'voice', 'video', 'send']);
      await tester.tap(field);
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      expect(editable.widget.focusNode.hasFocus, isTrue);
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(
        tester.state<EditableTextState>(find.byType(EditableText)),
        same(editable),
      );
      expect(editable.widget.focusNode.hasFocus, isTrue);
      tester.testTextInput.enterText('still typing');
      expect(controller.text, 'still typing');
      await tester.tap(find.byTooltip('Attachments'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Record video message'));
      await tester.pumpAndSettle();
      expect(actions.last, 'video');
      expect(tester.takeException(), isNull);
    },
  );
}
