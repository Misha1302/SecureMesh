import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:securemesh_client/voice_transcription.dart';
import 'package:securemesh_client/voice_wave.dart';

void main() {
  test(
    'missing cached model or network sandbox disables transcription',
    () async {
      final noModel = LocalVoiceTranscription(modelPath: '/missing/model.pt');
      expect(await noModel.available, isFalse);
      await expectLater(
        noModel.transcribe(Uint8List(8)),
        throwsA(isA<UnsupportedError>()),
      );

      final noSandbox = LocalVoiceTranscription(bwrapPath: '/missing/bwrap');
      expect(await noSandbox.available, isFalse);
    },
  );

  test(
    'cancellation during sandbox preflight never starts transcription',
    () async {
      final service = LocalVoiceTranscription();
      final wav = (VoiceSamples()..add(Uint8List(voiceRate * 2))).finish();
      final pending = service.transcribe(wav);
      service.cancel();
      await expectLater(pending, throwsA(isA<StateError>()));
    },
    skip: Platform.environment['SECUREMESH_LOCAL_WHISPER_TEST'] != '1'
        ? 'Opt-in: requires cached Whisper base model and Linux sandbox tools.'
        : null,
  );

  test(
    'configured local helper transcribes valid WAV in the isolated sandbox',
    () async {
      final service = LocalVoiceTranscription();
      expect(await service.available, isTrue);
      final before = Directory('/dev/shm')
          .listSync()
          .where(
            (entry) =>
                entry.path.split('/').last.startsWith('securemesh-voice-'),
          )
          .map((entry) => entry.path)
          .toSet();
      final wav = (VoiceSamples()..add(Uint8List(voiceRate * 2))).finish();
      expect(await service.transcribe(wav), isEmpty);
      final after = Directory('/dev/shm')
          .listSync()
          .where(
            (entry) =>
                entry.path.split('/').last.startsWith('securemesh-voice-'),
          )
          .map((entry) => entry.path)
          .toSet();
      expect(after.difference(before), isEmpty);
    },
    skip: Platform.environment['SECUREMESH_LOCAL_WHISPER_TEST'] != '1'
        ? 'Opt-in: requires cached Whisper base model and Linux sandbox tools.'
        : null,
  );
}
