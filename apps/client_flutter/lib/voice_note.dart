import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'voice_wave.dart';

typedef VoiceLabel = String Function(String, String);

// The Linux and Darwin audioplayers byte source writes an unmanaged cached
// copy. Use a private scratch directory with explicit teardown on those hosts.
Future<Directory>? _scratch;
Future<Directory> _voiceScratch() async {
  final cache = await getTemporaryDirectory();
  final root = Directory('${cache.path}/securemesh-voice');
  await root.create(recursive: true);
  await for (final item in root.list(followLinks: false)) {
    if (item is! Directory) continue;
    final marker = File('${item.path}/active');
    if (!await marker.exists()) continue;
    final lease = await marker.open(mode: FileMode.append);
    try {
      await lease.lock(FileLock.exclusive);
      await item.delete(recursive: true);
    } on FileSystemException {
      // Another running process owns this directory.
    } finally {
      await lease.close();
    }
  }
  return root;
}

class VoicePlayer extends StatefulWidget {
  const VoicePlayer(this.bytes, this.tr, {super.key});
  final Uint8List bytes;
  final VoiceLabel tr;
  @override
  State<VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<VoicePlayer> {
  AudioPlayer? player;
  late final Duration duration;
  Duration position = Duration.zero;
  bool playing = false, busy = false, failed = false;
  final subscriptions = <StreamSubscription<dynamic>>[];
  Directory? scratch;
  RandomAccessFile? lease;
  Future<void>? action;

  @override
  void initState() {
    super.initState();
    duration = voiceDuration(widget.bytes);
  }

  Future<void> prepare() async {
    if (player != null) return;
    final current = AudioPlayer();
    player = current;
    subscriptions.add(
      current.onPositionChanged.listen((d) {
        if (mounted) setState(() => position = d);
      }),
    );
    subscriptions.add(
      current.onPlayerStateChanged.listen((state) {
        if (mounted) {
          setState(() {
            playing = state == PlayerState.playing;
            if (state == PlayerState.completed) position = Duration.zero;
          });
        }
      }),
    );
    await current.setReleaseMode(ReleaseMode.stop);
    if (Platform.isLinux || Platform.isIOS || Platform.isMacOS) {
      final root = await (_scratch ??= _voiceScratch());
      final dir = await root.createTemp('clip-');
      scratch = dir;
      final lock = await File('${dir.path}/active').open(mode: FileMode.append);
      lease = lock;
      await lock.lock(FileLock.exclusive);
      final file = File('${dir.path}/note.wav');
      await file.writeAsBytes(widget.bytes, flush: true);
      await current.setSourceDeviceFile(file.path, mimeType: 'audio/wav');
    } else {
      await current.setSourceBytes(widget.bytes, mimeType: 'audio/wav');
    }
  }

  Future<void> run(Future<void> Function(AudioPlayer) op) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      action = () async {
        await prepare();
        if (mounted) await op(player!);
      }();
      await action;
    } catch (_) {
      if (mounted) setState(() => failed = true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> release() async {
    try {
      await action;
    } catch (_) {}
    try {
      for (final s in subscriptions) {
        await s.cancel();
      }
      await player?.dispose();
    } finally {
      await lease?.close();
      if (scratch != null && await scratch!.exists()) {
        await scratch!.delete(recursive: true);
      }
    }
  }

  @override
  void dispose() {
    unawaited(release().catchError((_) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ms = duration.inMilliseconds.clamp(1, 30000);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (failed)
          Text(
            widget.tr('Не удалось воспроизвести запись.', 'Playback failed.'),
          ),
        Row(
          children: [
            IconButton(
              tooltip: playing
                  ? widget.tr('Пауза', 'Pause')
                  : widget.tr('Воспроизвести', 'Play'),
              onPressed: busy || failed
                  ? null
                  : () => run((p) => playing ? p.pause() : p.resume()),
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
            ),
            Expanded(
              child: Slider(
                min: 0,
                max: ms.toDouble(),
                value: position.inMilliseconds.clamp(0, ms).toDouble(),
                semanticFormatterCallback: (v) => '${v ~/ 1000} s',
                onChanged: busy || failed
                    ? null
                    : (v) => setState(
                        () => position = Duration(milliseconds: v.round()),
                      ),
                onChangeEnd: (v) =>
                    run((p) => p.seek(Duration(milliseconds: v.round()))),
              ),
            ),
            Text(
              '${position.inSeconds.clamp(0, duration.inSeconds)}/${duration.inSeconds} s',
            ),
          ],
        ),
      ],
    );
  }
}

class VoiceDialog extends StatefulWidget {
  const VoiceDialog(
    this.tr, {
    this.received,
    this.makeRecorder = AudioRecorder.new,
    super.key,
  });
  final AudioRecorder Function() makeRecorder;
  final VoiceLabel tr;
  final Uint8List? received;
  @override
  State<VoiceDialog> createState() => _VoiceDialogState();
}

class _VoiceDialogState extends State<VoiceDialog> with WidgetsBindingObserver {
  AudioRecorder? recorder;
  StreamSubscription<Uint8List>? subscription;
  Timer? limit;
  VoiceSamples samples = VoiceSamples();
  Uint8List? clip;
  bool recording = false, busy = false, denied = false, error = false;
  int seconds = 0;
  bool abandoned = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    clip = widget.received;
  }

  Future<void> start() async {
    if (busy || recording || abandoned) return;
    setState(() {
      busy = true;
      denied = false;
      error = false;
    });
    final rec = recorder ??= widget.makeRecorder();
    try {
      if (!await rec.hasPermission()) {
        if (mounted) setState(() => denied = true);
        return;
      }
      if (!mounted || abandoned) return;
      samples = VoiceSamples();
      final stream = await rec.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: voiceRate,
          numChannels: 1,
        ),
      );
      if (!mounted || abandoned) return;
      setState(() {
        recording = true;
        seconds = 0;
      });
      subscription = stream.listen(
        (bytes) {
          if (!mounted || abandoned) return;
          final full = samples.add(bytes);
          if (seconds != samples.seconds) {
            setState(() => seconds = samples.seconds);
          }
          if (full && recording) unawaited(stop());
        },
        onError: (Object _) {
          if (recording) unawaited(stop(failed: true));
        },
        onDone: () {
          if (recording) unawaited(stop());
        },
      );
      limit = Timer(const Duration(seconds: voiceSeconds), () {
        if (recording) unawaited(stop());
      });
    } catch (_) {
      if (mounted) setState(() => error = true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> stop({bool failed = false}) async {
    if (!recording) return;
    setState(() {
      recording = false;
      busy = true;
    });
    limit?.cancel();
    try {
      await recorder?.stop();
      await subscription?.cancel();
      if (failed) throw StateError('record');
      if (mounted && !abandoned) setState(() => clip = samples.finish());
    } catch (_) {
      if (mounted) setState(() => error = true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused) &&
        mounted &&
        !abandoned &&
        ModalRoute.of(context)?.isCurrent == true) {
      abandoned = true;
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    abandoned = true;
    recording = false;
    limit?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(subscription?.cancel());
    unawaited(recorder?.dispose().catchError((_) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    final received = widget.received != null;
    return AlertDialog(
      title: Text(tr('Голосовое сообщение', 'Voice note')),
      content: SizedBox(
        width: 320,
        child: clip != null
            ? VoicePlayer(clip!, tr)
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    denied
                        ? tr(
                            'Разрешите доступ к микрофону в настройках приложения и повторите.',
                            'Allow microphone access in app settings and retry.',
                          )
                        : error
                        ? tr(
                            'Микрофон недоступен. Проверьте устройство и повторите.',
                            'Microphone unavailable. Check the input device and retry.',
                          )
                        : recording
                        ? tr(
                            'Запись · $seconds / 30 с',
                            'Recording · $seconds / 30 s',
                          )
                        : tr(
                            'До 30 секунд. Перед отправкой запись можно прослушать.',
                            'Up to 30 seconds. You can listen before sending.',
                          ),
                  ),
                  TextButton.icon(
                    onPressed: busy
                        ? null
                        : recording
                        ? stop
                        : start,
                    icon: Icon(recording ? Icons.stop : Icons.mic),
                    label: Text(
                      recording
                          ? tr('Остановить', 'Stop')
                          : tr('Записать', 'Record'),
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            abandoned = true;
            Navigator.pop(context);
          },
          child: Text(
            received ? tr('Закрыть', 'Close') : tr('Отмена', 'Cancel'),
          ),
        ),
        if (!received && clip != null)
          FilledButton(
            onPressed: () => Navigator.pop(context, clip),
            child: Text(tr('Отправить', 'Send')),
          ),
      ],
    );
  }
}
