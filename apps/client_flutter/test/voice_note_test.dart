import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:record/record.dart';
import 'package:securemesh_client/voice_note.dart';
import 'package:securemesh_client/voice_wave.dart';

class Mic extends Fake implements AudioRecorder {
  bool permission = false, released = false;
  final samples = StreamController<Uint8List>();
  @override
  Future<bool> hasPermission({bool request = true}) async => permission;
  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    expect(config.encoder, AudioEncoder.pcm16bits);
    expect(config.sampleRate, voiceRate);
    expect(config.numChannels, 1);
    return samples.stream;
  }

  @override
  Future<String?> stop() async => null;
  @override
  Future<void> dispose() async {
    released = true;
    await samples.close();
  }
}

void main() {
  test(
    'voice samples saturate at 30 seconds and enforce the WAV structure',
    () {
      final c = VoiceSamples();
      expect(c.add(Uint8List(2000000)), true);
      expect(c.add(Uint8List(24)), true);
      final bytes = c.finish();
      expect(bytes.length, 960044);
      expect(voiceDuration(bytes), const Duration(seconds: 30));
      final wrongRate = Uint8List.fromList(bytes)..[24] = 0;
      expect(() => voiceDuration(wrongRate), throwsFormatException);
      expect(
        () => voiceDuration(Uint8List.sublistView(bytes, 0, bytes.length - 1)),
        throwsFormatException,
      );
      expect(VoiceSamples().finish, throwsFormatException);
    },
  );
  testWidgets(
    'mic permission can be retried; stop previews; send returns only the clip',
    (t) async {
      final mic = Mic();
      Uint8List? result;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<Uint8List>(
                  context: context,
                  builder: (_) =>
                      VoiceDialog((ru, en) => en, makeRecorder: () => mic),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('Open'));
      await t.pumpAndSettle();
      await t.tap(find.text('Record'));
      await t.pumpAndSettle();
      expect(find.textContaining('Allow microphone'), findsOneWidget);
      mic.permission = true;
      await t.tap(find.text('Record'));
      await t.pumpAndSettle();
      mic.samples.add(Uint8List(32000));
      await t.pump();
      await t.tap(find.text('Stop'));
      await t.pump();
      // Stream cancellation completes in the platform event loop before the preview frame.
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pumpAndSettle();
      expect(find.byTooltip('Play'), findsOneWidget);
      expect(result, isNull);
      await t.tap(find.text('Send'));
      await t.pumpAndSettle();
      expect(voiceDuration(result!), const Duration(seconds: 1));
      expect(mic.released, isTrue);
    },
  );
  testWidgets(
    'cancelling active capture closes microphone and returns no bytes',
    (t) async {
      final mic = Mic()..permission = true;
      Object? result = Object();
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async {
                result = await showDialog<Uint8List>(
                  context: ctx,
                  builder: (_) =>
                      VoiceDialog((ru, en) => en, makeRecorder: () => mic),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('Open'));
      await t.pumpAndSettle();
      await t.tap(find.text('Record'));
      await t.pumpAndSettle();
      mic.samples.add(Uint8List(32000));
      await t.pump();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(result, isNull);
      expect(mic.released, isTrue);
    },
  );
}
