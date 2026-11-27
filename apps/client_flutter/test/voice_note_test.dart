import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:record/record.dart';
import 'package:securemesh_client/voice_note.dart';
import 'package:securemesh_client/conversation_composer.dart';
import 'package:securemesh_client/voice_wave.dart';

class Mic extends Fake implements AudioRecorder {
  bool permission = false, released = false, paused = false;
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
  Future<void> pause() async {
    paused = true;
  }

  @override
  Future<void> resume() async {
    paused = false;
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
  test('recording and received peaks reflect the PCM amplitude across split samples', () {
    final samples = VoiceSamples();
    final pcm = Uint8List(voiceRate * 2 ~/ 5 * 2);
    final data = ByteData.sublistView(pcm);
    for (var i = pcm.length ~/ 2; i < pcm.length; i += 2) {
      data.setInt16(i, -16384, Endian.little);
    }
    samples.add(Uint8List.sublistView(pcm, 0, 1));
    samples.add(Uint8List.sublistView(pcm, 1));
    expect(samples.peaks, [0.0, .5]);
    expect(voicePeaks(samples.finish(), bars: 2), [0.0, .5]);
  });
  testWidgets(
    'holding the composer mic cancels left, locks up, and previews before send',
    (t) async {
      String en(String ru, String english) => english;
      final results = <Uint8List?>[];
      var taps = 0;
      late Mic mic;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Align(
                alignment: Alignment.bottomCenter,
                child: ConversationComposer(
                  editor: const SizedBox(),
                  tr: en,
                  videoSupported: false,
                  onFile: null,
                  onVideo: null,
                  onSend: null,
                  onVoice: () => taps++,
                  onVoiceHold: (hold) async {
                    mic = Mic()..permission = true;
                    results.add(
                      await showHeldVoice(
                        ctx,
                        en,
                        hold,
                        makeRecorder: () => mic,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      final button = find.byTooltip('Record a voice note');
      Future<TestGesture> hold() async {
        final finger = await t.startGesture(t.getCenter(button));
        await t.pump(const Duration(milliseconds: 650));
        await t.pump();
        await t.pump();
        mic.samples.add(Uint8List(32000));
        await t.pump();
        return finger;
      }

      await t.tap(button);
      expect(taps, 1);
      var finger = await hold();
      await finger.moveBy(const Offset(-70, 0));
      await finger.up();
      await t.pumpAndSettle();
      expect(results, [null]);
      expect(mic.released, isTrue);
      finger = await hold();
      await finger.moveBy(const Offset(0, -70));
      await finger.up();
      await t.pump();
      expect(find.textContaining('Hands-free recording'), findsOneWidget);
      expect(find.text('Send'), findsNothing);
      await t.tap(find.text('Stop'));
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      finger = await hold();
      await finger.up();
      await t.pumpAndSettle();
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pumpAndSettle();
      expect(
        find.byTooltip('Play'),
        findsOneWidget,
        reason: t
            .widgetList<Text>(find.byType(Text))
            .map((e) => e.data)
            .join(' '),
      );
      expect(results, [null, null]);
      await t.tap(find.text('Send'));
      await t.pumpAndSettle();
      expect(voiceDuration(results.last!), const Duration(seconds: 1));
      expect(taps, 1);
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
      await t.tap(find.text('Pause recording'));
      await t.pumpAndSettle();
      expect(mic.paused, isTrue);
      mic.samples.add(Uint8List(32000));
      await t.pump();
      await t.tap(find.text('Resume recording'));
      await t.pumpAndSettle();
      expect(mic.paused, isFalse);
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
