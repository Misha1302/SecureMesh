import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:securemesh_client/attachment_transfer.dart';
import 'package:securemesh_client/video_message.dart';

void main() {
  late Uint8List clip;
  setUp(() => clip = File('test/fixtures/camera-clip.mp4').readAsBytesSync());

  test('plays a bounded self-contained H.264/AAC camera clip', () {
    expect(isLocalVideo(clip), isTrue);
    expect(videoRecordLimit, const Duration(seconds: 12));
  });
  test('refuses playlists, oversized files, truncated boxes and external track data', () {
    expect(
      isLocalVideo(
        Uint8List.fromList(utf8.encode('#EXTM3U\nhttps://example.com/track')),
      ),
      isFalse,
    );
    expect(isLocalVideo(Uint8List(attachmentLimit + 1)), isFalse);
    expect(
      isLocalVideo(Uint8List.sublistView(clip, 0, clip.length - 5)),
      isFalse,
    );
    final ref = latin1.decode(clip).indexOf('url ');
    expect(ref, greaterThan(0));
    clip[ref + 7] = 0;
    expect(isLocalVideo(clip), isFalse);
  });
  testWidgets(
    'inline video closes only the bubble and leaves its chat visible',
    (tester) async {
      bool open = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (_, update) => Column(
                children: [
                  const Text('Chat'),
                  if (open)
                    VideoMessageDialog(
                      tr: (_, en) => en,
                      received: Uint8List(1),
                      inline: true,
                      onClose: () => update(() => open = false),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Chat'), findsOneWidget);
      expect(find.byType(VideoMessageDialog), findsNothing);
    },
  );
  testWidgets('camera denial closes without sending or blocking the chat', (
    tester,
  ) async {
    Uint8List? result;
    var returned = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<Uint8List>(
                  context: context,
                  builder: (_) => VideoMessageDialog(
                    tr: (_, en) => en,
                    listCameras: () async =>
                        throw CameraException('CameraAccessDenied', 'denied'),
                  ),
                );
                returned = true;
              },
              child: const Text('Chat'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Chat'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Video unavailable.'), findsOneWidget);
    expect(find.text('Send'), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(result, isNull);
    expect(find.text('Chat'), findsOneWidget);
  });
}
