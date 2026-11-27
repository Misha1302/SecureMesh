import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/attachment_selection.dart';
import 'package:securemesh_client/desktop_file_drop.dart';

void main() {
  test(
    'a selection accepts regular local files and rejects special inputs',
    () async {
      final dir = await Directory.systemTemp.createTemp('securemesh-drop-test');
      addTearDown(() => dir.delete(recursive: true));
      final file = await File.fromUri(dir.uri.resolve('document.txt'))
          .writeAsString('private');
      expect(
        (await localDroppedFiles([file.path, file.path])).single.name,
        'document.txt',
      );
      for (final paths in [
        ['https://example.invalid/private'],
        ['file:///etc/hosts'],
        [dir.path],
        [List.filled(20, 'a')],
        List.filled(maxDroppedFiles + 1, file.path),
        [file.path, 'relative'],
      ]) {
        expect(await localDroppedFiles(paths), isEmpty);
      }
      if (!Platform.isWindows) {
        final link = await Link('${dir.path}/link').create(file.path);
        expect(await localDroppedFiles([link.path]), isEmpty);
      }
    },
  );
  testWidgets(
    'drop needs an enabled composer and explicit dialog confirmation',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      void drop() => messenger.handlePlatformMessage(
        desktopDropChannel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('drop', [
            File.fromUri(Directory.systemTemp.uri.resolve('one.txt')).path,
          ]),
        ),
        (_) {},
      );
      var confirmed = false;
      var dialogs = 0;
      Widget app(bool enabled) => MaterialApp(
        home: Builder(
          builder: (context) => DesktopFileDrop(
            onFiles: enabled
                ? (paths) async {
                    dialogs++;
                    final selection = await showDialog(
                      context: context,
                      builder: (_) => AttachmentSelection([
                        XFile(paths.single as String),
                      ], (_, en) => en),
                    );
                    confirmed = selection != null;
                  }
                : null,
            child: const SizedBox(),
          ),
        ),
      );
      await tester.pumpWidget(app(false));
      drop();
      await tester.pumpAndSettle();
      expect(dialogs, 0);
      await tester.pumpWidget(app(true));
      drop();
      await tester.pumpAndSettle();
      expect(find.text('one.txt'), findsOneWidget);
      drop();
      await tester.pumpAndSettle();
      expect(dialogs, 1);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(confirmed, false);
      drop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(confirmed, true);
    },
    skip: !(Platform.isLinux || Platform.isWindows),
  );
}
