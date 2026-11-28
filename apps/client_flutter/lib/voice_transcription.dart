import 'dart:io';
import 'dart:typed_data';

import 'voice_wave.dart';

/// Transcribes only with an already-installed local Whisper CLI and cached
/// base model. The input and output stay in a private temporary directory.
class LocalVoiceTranscription {
  const LocalVoiceTranscription();

  Future<bool> get available async {
    if (!Platform.isLinux) return false;
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return false;
    final model = File('$home/.cache/whisper/base.pt');
    if (await FileSystemEntity.type(model.path) != FileSystemEntityType.file)
      return false;
    try {
      final result = await Process.run('which', ['whisper']);
      return result.exitCode == 0 &&
          (result.stdout as String).trim().isNotEmpty;
    } on ProcessException {
      return false;
    }
  }

  Future<String> transcribe(Uint8List wav) async {
    if (!Platform.isLinux) throw UnsupportedError('Linux only');
    voiceDuration(
      wav,
    ); // Reject malformed or oversized input before writing it.
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty)
      throw StateError('Local model unavailable');
    final model = File('$home/.cache/whisper/base.pt');
    if (await FileSystemEntity.type(model.path) != FileSystemEntityType.file)
      throw StateError('Local model unavailable');
    final lookup = await Process.run('which', ['whisper']);
    final executable = (lookup.stdout as String).trim();
    if (lookup.exitCode != 0 || executable.isEmpty) {
      throw StateError('Local Whisper unavailable');
    }

    final scratch = await Directory.systemTemp.createTemp('securemesh-voice-');
    try {
      final input = File('${scratch.path}/voice.wav');
      await input.writeAsBytes(wav, flush: true);
      final result = await Process.run(executable, [
        '--model',
        'base',
        '--model_dir',
        '$home/.cache/whisper',
        '--device',
        'cpu',
        '--fp16',
        'False',
        '--verbose',
        'False',
        '--output_dir',
        scratch.path,
        '--output_format',
        'txt',
        input.path,
      ]);
      if (result.exitCode != 0) throw StateError('Transcription failed');
      final output = File('${scratch.path}/voice.txt');
      if (await FileSystemEntity.type(output.path) != FileSystemEntityType.file)
        throw StateError('Transcription failed');
      return (await output.readAsString()).trim();
    } finally {
      await scratch.delete(recursive: true);
    }
  }
}
