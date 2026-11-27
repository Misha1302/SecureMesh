import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/attachment_selection.dart';
import 'package:securemesh_client/clipboard_photo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'clipboard bytes are bounded and converted to a metadata-free local PNG',
    () async {
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAD0lEQVR4nGP8z/CfgYEBAAoEAgDdrjB4AAAAAElFTkSuQmCC',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      Uint8List? source = Uint8List.fromList([
        ...png,
        ...utf8.encode('private-metadata-sentinel'),
      ]);
      messenger.setMockMethodCallHandler(clipboardPhotoChannel, (call) async {
        expect(call.method, 'read');
        return source;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(clipboardPhotoChannel, null),
      );
      final result = await readClipboardPhoto();
      expect(result!.sublist(0, 8), png.sublist(0, 8));
      expect(
        latin1.decode(result),
        isNot(contains('private-metadata-sentinel')),
      );
      source = Uint8List.fromList(utf8.encode('file:///private/profile'));
      await expectLater(readClipboardPhoto(), throwsFormatException);
      source = Uint8List(4 * 1024 * 1024 + 1);
      await expectLater(readClipboardPhoto(), throwsFormatException);
      source = null;
      expect(await readClipboardPhoto(), isNull);
    },
  );
  testWidgets('paste opens image preview and requires explicit confirmation', (
    tester,
  ) async {
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAD0lEQVR4nGP8z/CfgYEBAAoEAgDdrjB4AAAAAElFTkSuQmCC',
    );
    final file = XFile.fromData(
      png,
      path: 'clipboard-image.png',
      mimeType: 'image/png',
    );
    ({List<XFile> files, String caption})? accepted;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () async {
                accepted = await showDialog(
                  context: ctx,
                  builder: (_) =>
                      AttachmentSelection([file], (_, en) => en, preview: png),
                );
              },
              child: const Text('Paste image'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Paste image'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('clipboard-image.png'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(accepted, isNull);
    await tester.tap(find.text('Paste image'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Private caption');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(accepted!.caption, 'Private caption');
    expect(await accepted!.files.single.readAsBytes(), png);
    expect(File('clipboard-image.png').existsSync(), false);
  });
}
