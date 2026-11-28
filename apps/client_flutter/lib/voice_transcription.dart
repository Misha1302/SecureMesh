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
      ], includeParentEnvironment: false);
      final result = await _reap(
        probe,
        Future.wait([probe.stdout.drain<void>(), probe.stderr.drain<void>()]),
        const Duration(seconds: 3),
      );
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
        if (fields.length > 2 && fields[1] == path) {
          if (fields[2] != 'tmpfs') return false;
          final mode = (await Directory(path).stat()).mode;
          // A shared writable scratch mount must protect entries from other UIDs.
          return mode & 0x12 == 0 || mode & 0x200 != 0;
        }
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

  List<String> _sandboxArgs(
    String executable, {
    String? scratch,
    String? model,
  }) {
    final home = Platform.environment['HOME'];
    return [
      '--unshare-net',
      '--unshare-pid',
      '--unshare-ipc',
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
      '--tmpfs',
      '/var/tmp',
      '--tmpfs',
      '/home',
      for (final path in ['/mnt', '/media'])
        if (Directory(path).existsSync()) ...['--tmpfs', path],
      if (home != null && home.startsWith('/') && home != '/') ...[
        if (!home.startsWith('/home/')) ...['--tmpfs', home],
        '--ro-bind-try',
        '$home/.local/lib',
        '$home/.local/lib',
      ],
      if (scratch != null) ...['--bind', scratch, '/tmp'],
      if (model != null) ...[
        '--ro-bind',
        executable,
        executable,
        '--ro-bind',
        model,
        '/run/securemesh-model.pt',
      ],
      '--chdir',
      '/tmp',
      '--',
      executable,
    ];
  }

  static Future<int> _reap(
    Process process,
    Future<void> streams,
    Duration deadline,
  ) async {
    Future<int> completed() async {
      final code = await process.exitCode;
      await streams;
      return code;
    }

    final completion = completed();
    return completion.timeout(
      deadline,
      onTimeout: () async {
        process.kill(ProcessSignal.sigkill);
        await completion;
        throw TimeoutException('Transcription subprocess timed out');
      },
    );
  }

  Future<String> _scratchPrefix() async {
    final status = await File('/proc/self/status').readAsString();
    final uid = RegExp(
      r'^Uid:[ \t]+[0-9]+[ \t]+([0-9]+)',
      multiLine: true,
    ).firstMatch(status)?.group(1);
    final ns = RegExp(r'^pid:\[([0-9]+)\]$')
        .firstMatch(await Link('/proc/self/ns/pid').target())
        ?.group(1);
    if (uid == null || ns == null) {
      throw UnsupportedError('Cannot identify scratch owner');
    }

    final prefix = 'securemesh-voice-$uid-$ns-';
    final name = RegExp(
      '^${RegExp.escape(prefix)}([1-9][0-9]*)-[a-zA-Z0-9]+\$',
    );
    try {
      await for (final entry in Directory(
        scratchRoot,
      ).list(followLinks: false)) {
        // The sticky parent prevents a different UID from replacing an owned entry.
        if (entry is! Directory) continue;
        final owner = name
            .firstMatch(
              entry.uri.pathSegments
                  .where((segment) => segment.isNotEmpty)
                  .last,
            )
            ?.group(1);
        if (owner == null || owner == '$pid') continue;
        if (await FileSystemEntity.type('/proc/$owner') !=
            FileSystemEntityType.notFound) {
          continue;
        }
        try {
          final stat = await Process.run('/usr/bin/stat', [
            '--format=%u:%a',
            '--',
            entry.path,
          ], includeParentEnvironment: false);
          if (stat.exitCode == 0 &&
              (stat.stdout as String).trim() == '$uid:700') {
            await entry.delete(recursive: true);
          }
        } on FileSystemException {
          // Another local session may have reaped the same orphan.
        }
      }
    } on FileSystemException {
      // An unsuccessful sweep does not affect this invocation's own cleanup.
    }
    return '$prefix$pid-';
  }

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
    final prefix = await _scratchPrefix();
    _ensureCurrent(generation);
    final scratch = await Directory(scratchRoot).createTemp(prefix);
    try {
      _ensureCurrent(generation);
      final input = File('${scratch.path}/voice.wav');
      await input.writeAsBytes(wav, flush: true);
      _ensureCurrent(generation);
      final resultFile = '${scratch.path}/voice.txt';
      final args = _sandboxArgs(whisper, scratch: scratch.path, model: model)
        ..addAll([
          '--model',
          '/run/securemesh-model.pt',
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
        [
          '--as=8589934592',
          '--cpu=120',
          '--fsize=1048576',
          '--',
          bwrapPath,
          ...args,
        ],
        includeParentEnvironment: false,
        environment: {
          'PATH': '/usr/bin:/bin',
          'HOME': Platform.environment['HOME'] ?? '',
          'TMPDIR': '/tmp',
          'OMP_NUM_THREADS': '1',
          'OPENBLAS_NUM_THREADS': '1',
          'MKL_NUM_THREADS': '1',
        },
      );
      _process = process;
      final logs = <int>[];
      Future<void> drain(Stream<List<int>> stream) async {
        await for (final bytes in stream) {
          logs.addAll(bytes);
          if (logs.length > 4096) {
            logs.removeRange(0, logs.length - 4096);
          }
        }
      }

      final streams = Future.wait([
        drain(process.stdout),
        drain(process.stderr),
      ]);
      if (generation != _generation) process.kill(ProcessSignal.sigkill);
      final exit = await _reap(process, streams, maxRuntime);
      _process = null;
      _ensureCurrent(generation);
      if (exit != 0) {
        final detail = utf8.decode(logs, allowMalformed: true).trim();
        throw StateError(
          detail.isEmpty ? 'Transcription failed ($exit)' : detail,
        );
      }
      final transcript = File(resultFile);
      if (await FileSystemEntity.type(resultFile, followLinks: false) !=
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
      final text = await transcript.readAsString();
      _ensureCurrent(generation);
      return text.trim();
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
