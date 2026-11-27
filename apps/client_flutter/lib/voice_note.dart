import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'voice_wave.dart';

typedef VoiceLabel = String Function(String, String);

/// Kept only while the owning profile is unlocked.
class VoicePlaybackPositions {
  final _positions = <(String, String), Duration>{};

  Duration read(String conversation, String attachment) =>
      _positions[(conversation, attachment)] ?? Duration.zero;

  void save(String conversation, String attachment, Duration position) {
    final key = (conversation, attachment);
    if (position == Duration.zero) {
      _positions.remove(key);
    } else {
      _positions[key] = position;
    }
  }
}

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
  const VoicePlayer(
    this.bytes,
    this.tr, {
    super.key,
    this.resumeAt = Duration.zero,
    this.onPosition,
    this.makePlayer = AudioPlayer.new,
  });
  final Uint8List bytes;
  final VoiceLabel tr;
  final Duration resumeAt;
  final ValueChanged<Duration>? onPosition;
  final AudioPlayer Function() makePlayer;
  @override
  State<VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<VoicePlayer> {
  AudioPlayer? player;
  late final Duration duration;
  late final List<double> peaks;
  double rate = 1;
  bool rateUnavailable = false;
  late Duration position;
  bool playing = false, busy = false, failed = false, scrubbing = false;
  final subscriptions = <StreamSubscription<dynamic>>[];
  Directory? scratch;
  RandomAccessFile? lease;
  Future<void>? action;

  @override
  void initState() {
    super.initState();
    duration = voiceDuration(widget.bytes);
    peaks = voicePeaks(widget.bytes);
    position = clamp(widget.resumeAt);
  }

  Duration clamp(Duration value) =>
      value.isNegative ? Duration.zero : (value > duration ? duration : value);

  void rememberPosition(Duration value) {
    position = clamp(value);
    widget.onPosition?.call(position);
  }

  Future<void> prepare() async {
    if (player != null) return;
    final current = widget.makePlayer();
    player = current;
    subscriptions.add(
      current.onPositionChanged.listen((d) {
        if (mounted && playing && !busy && !scrubbing) {
          setState(() => rememberPosition(d));
        }
      }),
    );
    subscriptions.add(
      current.onPlayerStateChanged.listen((state) {
        if (mounted) {
          setState(() {
            playing = state == PlayerState.playing;
            if (state == PlayerState.completed) rememberPosition(Duration.zero);
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
    final resumeAt = clamp(widget.resumeAt);
    if (mounted && resumeAt != Duration.zero) await current.seek(resumeAt);
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
        SizedBox(
          height: 28,
          width: double.infinity,
          child: CustomPaint(
            painter: _WavePainter(
              peaks,
              position.inMicroseconds / duration.inMicroseconds,
              Theme.of(context).colorScheme,
            ),
          ),
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
                onChangeStart: (_) => scrubbing = true,
                onChangeEnd: (v) {
                  scrubbing = false;
                  final target = Duration(milliseconds: v.round());
                  run((p) async {
                    await p.seek(target);
                    if (mounted) setState(() => rememberPosition(target));
                  });
                },
              ),
            ),
            Text(
              '${position.inSeconds.clamp(0, duration.inSeconds)}/${duration.inSeconds} s',
            ),
          ],
        ),
        PopupMenuButton<double>(
          tooltip: widget.tr('Скорость воспроизведения', 'Playback speed'),
          enabled: !busy && !failed && !rateUnavailable,
          initialValue: rate,
          onSelected: (value) => run((p) async {
            try {
              await p.setPlaybackRate(value);
              if (mounted) setState(() => rate = value);
            } catch (_) {
              if (mounted) setState(() => rateUnavailable = true);
            }
          }),
          itemBuilder: (_) => [
            for (final speed in [1.0, 1.5, 2.0])
              PopupMenuItem(value: speed, child: Text('$speed×')),
          ],
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              rateUnavailable
                  ? widget.tr(
                      'Смена скорости недоступна',
                      'Speed control unavailable',
                    )
                  : '$rate×',
            ),
          ),
        ),
      ],
    );
  }
}

class _WavePainter extends CustomPainter {
  const _WavePainter(this.peaks, this.progress, this.colors);
  final List<double> peaks;
  final double progress;
  final ColorScheme colors;
  @override
  void paint(Canvas canvas, Size size) {
    final step = size.width / peaks.length;
    final paint = Paint()
      ..strokeWidth = (step * .55).clamp(1.0, 4.0)
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < peaks.length; i++) {
      paint.color = (i + .5) / peaks.length <= progress
          ? colors.primary
          : colors.outline;
      final h = (peaks[i] * (size.height - 3)).clamp(1.0, size.height);
      final x = step * (i + .5);
      canvas.drawLine(
        Offset(x, (size.height - h) / 2),
        Offset(x, (size.height + h) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.peaks != peaks || old.progress != progress || old.colors != colors;
}

enum VoiceHold { recording, locked, preview, cancelled }

/// Overlay insertion keeps the initiating pointer in the composer's gesture
/// arena. Pushing a Navigator route here would cancel the ongoing long press.
Future<Uint8List?> showHeldVoice(
  BuildContext context,
  VoiceLabel tr,
  ValueNotifier<VoiceHold> hold, {
  AudioRecorder Function() makeRecorder = AudioRecorder.new,
}) {
  if (!context.mounted ||
      hold.value == VoiceHold.cancelled ||
      hold.value == VoiceHold.preview) {
    return Future.value();
  }
  final result = Completer<Uint8List?>();
  late final OverlayEntry overlay;
  late final LocalHistoryEntry back;
  void finish([Uint8List? clip]) {
    if (result.isCompleted) return;
    result.complete(clip);
    back.remove();
    overlay.remove();
    overlay.dispose();
  }

  back = LocalHistoryEntry(onRemove: finish, impliesAppBarDismissal: false);
  overlay = OverlayEntry(
    builder: (_) => BlockSemantics(
      child: Stack(
        children: [
          const ModalBarrier(dismissible: false, color: Colors.black54),
          FocusScope(
            autofocus: true,
            child: SafeArea(
              child: VoiceDialog(
                tr,
                hold: hold,
                onFinish: finish,
                makeRecorder: makeRecorder,
              ),
            ),
          ),
        ],
      ),
    ),
  );
  ModalRoute.of(context)!.addLocalHistoryEntry(back);
  Overlay.of(context).insert(overlay);
  return result.future;
}

class VoiceDialog extends StatefulWidget {
  const VoiceDialog(
    this.tr, {
    this.received,
    this.makeRecorder = AudioRecorder.new,
    this.hold,
    this.onFinish,
    super.key,
  });
  final ValueNotifier<VoiceHold>? hold;
  final void Function([Uint8List? clip])? onFinish;
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
  final activeTime = Stopwatch();
  bool paused = false, pauseUnavailable = false;
  bool abandoned = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    clip = widget.received;
    if (widget.hold != null) {
      widget.hold!.addListener(holdChanged);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || abandoned) return;
        final state = widget.hold!.value;
        if (state == VoiceHold.cancelled || state == VoiceHold.preview) {
          finish();
          return;
        }
        unawaited(start());
      });
    }
  }

  void finish([Uint8List? value]) {
    if (abandoned) return;
    abandoned = true;
    if (widget.onFinish != null) {
      widget.onFinish!(value);
    } else {
      Navigator.pop(context, value);
    }
  }

  void holdChanged() {
    if (!mounted || abandoned) return;
    switch (widget.hold!.value) {
      case VoiceHold.cancelled:
        finish();
      case VoiceHold.preview:
        if (recording) {
          unawaited(stop());
        } else if (clip == null && !denied && !error) {
          finish();
        }
      case VoiceHold.locked:
        setState(() {});
      case VoiceHold.recording:
        break;
    }
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
        paused = pauseUnavailable = false;
        seconds = 0;
      });
      subscription = stream.listen(
        (bytes) {
          if (!mounted || abandoned || paused) return;
          final previousBins = samples.peaks.length;
          final full = samples.add(bytes);
          if (previousBins != samples.peaks.length) {
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
      activeTime
        ..reset()
        ..start();
      armLimit();
    } catch (_) {
      if (mounted) setState(() => error = true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void armLimit() {
    limit?.cancel();
    limit = Timer(
      const Duration(seconds: voiceSeconds) - activeTime.elapsed,
      () {
        if (mounted && recording && !abandoned) unawaited(stop());
      },
    );
  }

  Future<void> togglePause() async {
    if (busy || !recording) return;
    setState(() => busy = true);
    try {
      if (paused) {
        await recorder!.resume();
      } else {
        await recorder!.pause();
      }
      if (!mounted || abandoned || !recording) return;
      paused = !paused;
      if (paused) {
        activeTime.stop();
        limit?.cancel();
      } else {
        activeTime.start();
        armLimit();
      }
    } catch (_) {
      if (mounted) pauseUnavailable = true;
    } finally {
      if (mounted && recording && !abandoned) setState(() => busy = false);
    }
  }

  Future<void> stop({bool failed = false}) async {
    if (!recording) return;
    setState(() {
      recording = false;
      busy = true;
    });
    limit?.cancel();
    activeTime.stop();
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
        (widget.onFinish != null ||
            ModalRoute.of(context)?.isCurrent == true)) {
      finish();
    }
  }

  @override
  void dispose() {
    widget.hold?.removeListener(holdChanged);
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
                        : paused && recording
                        ? tr(
                            'Запись приостановлена · $seconds с',
                            'Recording paused · $seconds s',
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
                  if (recording && widget.hold != null)
                    Text(
                      widget.hold!.value == VoiceHold.locked
                          ? tr(
                              'Запись закреплена. Нажмите «Остановить» для прослушивания.',
                              'Hands-free recording. Stop to preview.',
                            )
                          : tr(
                              'Влево — отменить, вверх — закрепить. Отпустите для прослушивания.',
                              'Slide left to cancel or up to lock. Release to preview.',
                            ),
                    ),
                  if (recording && samples.peaks.isNotEmpty)
                    SizedBox(
                      height: 28,
                      width: double.infinity,
                      child: CustomPaint(
                        painter: _WavePainter(
                          [
                            ...List<double>.filled(
                              (36 - samples.peaks.length).clamp(0, 36),
                              0,
                            ),
                            ...samples.peaks.skip(
                              (samples.peaks.length - 36).clamp(
                                0,
                                samples.peaks.length,
                              ),
                            ),
                          ],
                          1,
                          Theme.of(context).colorScheme,
                        ),
                      ),
                    ),
                  if (recording && !pauseUnavailable)
                    TextButton.icon(
                      onPressed: busy ? null : togglePause,
                      icon: Icon(paused ? Icons.mic : Icons.pause),
                      label: Text(
                        paused
                            ? tr('Продолжить запись', 'Resume recording')
                            : tr('Пауза записи', 'Pause recording'),
                      ),
                    ),
                  if (recording && pauseUnavailable)
                    Text(
                      tr(
                        'Пауза на этом устройстве недоступна.',
                        'Recording pause is unavailable on this device.',
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
          onPressed: finish,
          child: Text(
            received ? tr('Закрыть', 'Close') : tr('Отмена', 'Cancel'),
          ),
        ),
        if (!received && clip != null)
          FilledButton(
            onPressed: () => finish(clip),
            child: Text(tr('Отправить', 'Send')),
          ),
      ],
    );
  }
}
