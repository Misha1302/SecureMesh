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
    'sweep removes only private scratch from a dead owner in this PID namespace',
    () async {
      final service = LocalVoiceTranscription();
      final scratch = Directory('/dev/shm');
      final owner = (await Process.run('/usr/bin/id', [
        '-u',
      ])).stdout.toString().trim();
      final namespace = RegExp(r'[0-9]+')
          .firstMatch(await Link('/proc/self/ns/pid').target())!
          .group(0)!;
      final prefix = 'securemesh-voice-$owner-$namespace-';
      final dead = await Process.start('/usr/bin/sleep', ['30']);
      final active = await Process.start('/usr/bin/sleep', ['30']);
      addTearDown(() async {
        active.kill(ProcessSignal.sigkill);
        await active.exitCode;
      });
      final orphan = await scratch.createTemp('$prefix${dead.pid}-');
      final stillInUse = await scratch.createTemp('$prefix${active.pid}-');
      final unrelated = await scratch.createTemp('$prefix${dead.pid}-');
      final symlink = Link('${unrelated.path}link');
      final foreignNamespace = await scratch.createTemp(
        'securemesh-voice-$owner-0-${dead.pid}-',
      );
      addTearDown(() async {
        if (await symlink.exists()) await symlink.delete();
        for (final directory in [
          orphan,
          stillInUse,
          unrelated,
          foreignNamespace,
        ]) {
          if (await directory.exists()) await directory.delete(recursive: true);
        }
      });
      await symlink.create(stillInUse.path);
      expect(
        (await Process.run('/usr/bin/chmod', ['755', unrelated.path])).exitCode,
        0,
      );
      dead.kill(ProcessSignal.sigkill);
      await dead.exitCode;

      final wav = (VoiceSamples()..add(Uint8List(voiceRate * 2))).finish();
      await service.transcribe(wav);
      expect(await orphan.exists(), isFalse);
      expect(await stillInUse.exists(), isTrue);
      expect(await unrelated.exists(), isTrue);
      expect(await foreignNamespace.exists(), isTrue);
      expect(await symlink.exists(), isTrue);
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
