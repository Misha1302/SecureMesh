import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'voice_wave.dart';

/// Linux-only, opt-in inference through a cached OpenAI Whisper model.
/// It requires bubblewrap network isolation and keeps plaintext audio on tmpfs.
class LocalVoiceTranscription {
  LocalVoiceTranscription({
    this.whisperPath,
    this.modelPath,
    this.bwrapPath = '/usr/bin/bwrap',
    this.prlimitPath = '/usr/bin/prlimit',
    this.scratchRoot = '/dev/shm',
  });

  final String? whisperPath;
  final String? modelPath;
  final String bwrapPath;
  final String prlimitPath;
  final String scratchRoot;
  static const maxRuntime = Duration(minutes: 2);
  Process? _process;
  int _generation = 0;

  void _ensureCurrent(int generation) {
    if (generation != _generation) throw StateError('Transcription cancelled');
  }

  Future<bool> get available async {
    if (!Platform.isLinux) return false;
    final whisper = await _resolveWhisper();
    final model = _resolveModel();
    if (whisper == null ||
        model == null ||
        await FileSystemEntity.type(whisper) != FileSystemEntityType.file ||
        await FileSystemEntity.type(model) != FileSystemEntityType.file ||
        await FileSystemEntity.type(bwrapPath) != FileSystemEntityType.file ||
        await FileSystemEntity.type(prlimitPath) != FileSystemEntityType.file ||
        await FileSystemEntity.type(scratchRoot) !=
            FileSystemEntityType.directory) {
      return false;
    }
    if (!await _isTmpfs(scratchRoot)) return false;
    try {
      final probe = await Process.start(prlimitPath, [
        '--as=8589934592',
        '--cpu=120',
        '--',
        bwrapPath,
        ..._sandboxArgs('/usr/bin/true'),
      ]);
      final result = await probe.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () async {
          probe.kill(ProcessSignal.sigkill);
          await probe.exitCode;
          throw TimeoutException('Sandbox probe timed out');
        },
      );
      await Future.wait([
        probe.stdout.drain<void>(),
        probe.stderr.drain<void>(),
      ]);
      return result == 0;
    } on Object {
      return false;
    }
  }

  Future<bool> _isTmpfs(String path) async {
    try {
      final lines = await File('/proc/mounts').readAsLines();
      for (final line in lines) {
        final fields = line.split(' ');
        if (fields.length > 2 && fields[1] == path) return fields[2] == 'tmpfs';
      }
    } on FileSystemException {
      return false;
    }
    return false;
  }

  String? _resolveModel() {
    if (modelPath != null) return modelPath;
    final home = Platform.environment['HOME'];
    return home == null || home.isEmpty ? null : '$home/.cache/whisper/base.pt';
  }

  Future<String?> _resolveWhisper() async {
    if (whisperPath != null) return whisperPath;
    try {
      final result = await Process.run('which', ['whisper']);
      final path = (result.stdout as String).trim();
      return result.exitCode == 0 && path.isNotEmpty ? path : null;
    } on Object {
      return null;
    }
  }

  List<String> _sandboxArgs(String executable, {String? scratch}) => [
    '--unshare-net',
    '--unshare-pid',
    '--die-with-parent',
    '--ro-bind',
    '/',
    '/',
    '--dev',
    '/dev',
    '--proc',
    '/proc',
    '--tmpfs',
    '/run',
    '--tmpfs',
    '/tmp',
    if (scratch != null) ...['--bind', scratch, '/tmp'],
    '--',
    executable,
  ];

  Future<String> transcribe(Uint8List wav) async {
    final generation = _generation;
    if (!Platform.isLinux || !await available) {
      throw UnsupportedError('Offline transcription sandbox unavailable');
    }
    _ensureCurrent(generation);
    voiceDuration(wav);
    final whisper = await _resolveWhisper();
    final model = _resolveModel();
    if (whisper == null || model == null) {
      throw UnsupportedError('Offline transcription unavailable');
    }
    _ensureCurrent(generation);
    final scratch = await Directory(scratchRoot)
        .createTemp('securemesh-voice-');
    try {
      _ensureCurrent(generation);
      final input = File('${scratch.path}/voice.wav');
      await input.writeAsBytes(wav, flush: true);
      _ensureCurrent(generation);
      final resultFile = '${scratch.path}/voice.txt';
      final args = _sandboxArgs(whisper, scratch: scratch.path)
        ..addAll([
          '--model',
          model,
          '--device',
          'cpu',
          '--fp16',
          'False',
          '--threads',
          '1',
          '--verbose',
          'False',
          '--output_dir',
          '/tmp',
          '--output_format',
          'txt',
          '/tmp/voice.wav',
        ]);
      final process = await Process.start(
        prlimitPath,
        ['--as=8589934592', '--cpu=120', '--', bwrapPath, ...args],
        includeParentEnvironment: false,
        environment: {
          'PATH':
              '/usr/bin:/bin:${Platform.environment['HOME'] ?? ''}/.local/bin',
          'HOME': Platform.environment['HOME'] ?? '',
          'TMPDIR': '/tmp',
          'OMP_NUM_THREADS': '1',
          'OPENBLAS_NUM_THREADS': '1',
          'MKL_NUM_THREADS': '1',
        },
      );
      _process = process;
      if (generation != _generation) {
        process.kill(ProcessSignal.sigkill);
        throw StateError('Transcription cancelled');
      }
      final logs = <int>[];
      Future<void> drain(Stream<List<int>> stream) async {
        await for (final bytes in stream) {
          logs.addAll(bytes);
          if (logs.length > 4096) {
            logs.removeRange(0, logs.length - 4096);
          }
        }
      }

      final stdoutDrain = drain(process.stdout);
      final stderrDrain = drain(process.stderr);
      var timedOut = false;
      final exit = await process.exitCode.timeout(
        maxRuntime,
        onTimeout: () async {
          timedOut = true;
          process.kill(ProcessSignal.sigkill);
          await process.exitCode;
          return -1;
        },
      );
      await Future.wait([stdoutDrain, stderrDrain]);
      _process = null;
      if (timedOut) throw TimeoutException('Transcription timed out');
      _ensureCurrent(generation);
      if (exit != 0) {
        final detail = utf8.decode(logs, allowMalformed: true).trim();
        throw StateError(
          detail.isEmpty ? 'Transcription failed ($exit)' : detail,
        );
      }
      final transcript = File(resultFile);
      if (await FileSystemEntity.type(resultFile) !=
          FileSystemEntityType.file) {
        final names = await Directory(scratch.path)
            .list()
            .map((entry) => entry.uri.pathSegments.last)
            .toList();
        final detail = utf8.decode(logs, allowMalformed: true).trim();
        throw StateError('Transcription output missing; files=$names; $detail');
      }
      if (await transcript.length() > 32768) {
        throw StateError('Transcription output too large');
      }
      return (await transcript.readAsString()).trim();
    } finally {
      _process = null;
      await scratch.delete(recursive: true);
    }
  }

  void cancel() {
    _generation++;
    _process?.kill(ProcessSignal.sigkill);
  }
}
