import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import 'attachment_transfer.dart';

const videoRecordLimit = Duration(seconds: 12);
const videoPlaybackLimit = Duration(
  seconds: 14,
); // Native recorder finalization.
bool get supportsVideoMessages => Platform.isAndroid || Platform.isIOS;

// Restrict the local player to self-contained camera MP4s. In particular,
// reject reference movies, external track data and playlist-like inputs.
bool isLocalVideo(Uint8List bytes) {
  if (bytes.length < 24 || bytes.length > attachmentLimit) return false;
  final data = ByteData.sublistView(bytes);
  var movie = false;
  var payload = false;
  var tracks = 0;
  var localReferences = 0;
  bool boxes(int start, int end, String parent) {
    for (var i = start; i < end;) {
      if (end - i < 8) return false;
      var size = data.getUint32(i);
      final type = String.fromCharCodes(bytes, i + 4, i + 8);
      var header = 8;
      if (size == 1) {
        // Some native muxers reserve the 64-bit mdat header even on short clips.
        if (end - i < 16 || data.getUint32(i + 8) != 0) return false;
        size = data.getUint32(i + 12);
        header = 16;
      } else if (size == 0 && parent.isEmpty && type == 'mdat') {
        size = end - i;
      }
      if (size < header || size > end - i) return false;
      final body = i + header;
      final stop = i + size;
      if (i == 0 && type != 'ftyp') return false;
      if (type == 'rmra' || type == 'moof' || type == 'mvex') return false;
      const parents = {
        'moov': '',
        'trak': 'moov',
        'mdia': 'trak',
        'minf': 'mdia',
        'dinf': 'minf',
        'dref': 'dinf',
      };
      if (parents.containsKey(type)) {
        if (parent != parents[type]) return false;
        if (type == 'moov') {
          if (movie) return false;
          movie = true;
        }
        if (type == 'trak') tracks++;
        if (type == 'dref') {
          if (stop - body != 20 ||
              data.getUint32(body + 4) != 1 ||
              data.getUint32(body + 8) != 12 ||
              String.fromCharCodes(bytes, body + 12, body + 16) != 'url ' ||
              data.getUint32(body + 16) != 1) {
            return false;
          }
          localReferences++;
        } else if (!boxes(body, stop, type)) {
          return false;
        }
      }
      if (type == 'mdat' && parent.isEmpty && stop > body) payload = true;
      i = stop;
    }
    return true;
  }

  return boxes(0, bytes.length, '') &&
      movie &&
      payload &&
      tracks > 0 &&
      localReferences == tracks;
}

class VideoScratch {
  static Future<Directory>? _root;
  static Future<Directory> root() => _root ??= _open();
  static Future<Directory> _open() async {
    final dir = Directory(
      '${(await getTemporaryDirectory()).path}/securemesh-video-v1',
    );
    if (await dir.exists()) await dir.delete(recursive: true);
    return dir.create();
  }
}

class VideoMessageDialog extends StatefulWidget {
  const VideoMessageDialog({
    super.key,
    required this.tr,
    this.received,
    this.inline = false,
    this.onClose,
    this.listCameras = availableCameras,
  }) : assert(!inline || (received != null && onClose != null));
  final bool inline;
  final VoidCallback? onClose;
  final Future<List<CameraDescription>> Function() listCameras;
  final String Function(String, String) tr;
  final Uint8List? received;
  @override
  State<VideoMessageDialog> createState() => _VideoMessageDialogState();
}

class _VideoMessageDialogState extends State<VideoMessageDialog>
    with WidgetsBindingObserver {
  CameraController? camera;
  List<CameraDescription> cameras = const [];
  final elapsed = Stopwatch();
  bool paused = false, pauseUnavailable = false;
  Route<void>? fullscreen;
  VideoPlayerController? player;
  Directory? folder;
  File get file => File('${folder!.path}/clip.mp4');
  Timer? timer;
  bool busy = true;
  bool recording = false;
  bool closed = false;
  bool failed = false;
  Future<void> pending = Future.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    pending = run(() async {
      final received = widget.received;
      if (received != null && !isLocalVideo(received)) {
        throw const FormatException();
      }
      cameras = received == null
          ? await widget.listCameras()
          : const <CameraDescription>[];
      if (closed) return;
      folder = await (await VideoScratch.root()).createTemp('clip-');
      if (closed) return;
      if (received != null) {
        await file.writeAsBytes(received, flush: true);
        await preview();
        return;
      }
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      camera = CameraController(
        front,
        ResolutionPreset.medium,
        videoBitrate: 750000,
        audioBitrate: 48000,
      );
      await camera!.initialize();
    });
  }

  Future<void> run(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      failed = true;
    } finally {
      if (mounted && !closed) setState(() => busy = false);
    }
  }

  void perform(Future<void> Function() action) {
    if (busy || closed) return;
    setState(() => busy = true);
    pending = run(action);
  }

  Future<void> start() async {
    await CameraPlatform.instance.startVideoCapturing(
      VideoCaptureOptions(
        camera!.cameraId,
        videoOutputPath: file.path,
        enablePersistentRecording: false,
      ),
    );
    recording = true;
    elapsed
      ..reset()
      ..start();
    if (!closed) {
      timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted || closed || !recording) return;
        if (elapsed.elapsed >= videoRecordLimit && !busy) {
          perform(stop);
        } else if (!paused) {
          setState(() {});
        }
      });
    }
  }

  Future<void> togglePause() async {
    try {
      if (paused) {
        await CameraPlatform.instance.resumeVideoRecording(camera!.cameraId);
      } else {
        await CameraPlatform.instance.pauseVideoRecording(camera!.cameraId);
      }
      if (closed) return;
      paused = !paused;
      if (paused) {
        elapsed.stop();
      } else {
        elapsed.start();
      }
    } catch (_) {
      pauseUnavailable = true;
    }
  }

  Future<void> switchCamera() async {
    final current = camera!.description;
    final next = cameras.firstWhere(
      (c) => c.lensDirection != current.lensDirection,
      orElse: () => cameras[(cameras.indexOf(current) + 1) % cameras.length],
    );
    await camera!.setDescription(next);
  }

  Future<void> stop() async {
    timer?.cancel();
    elapsed.stop();
    final result = await CameraPlatform.instance.stopVideoRecording(
      camera!.cameraId,
    );
    recording = false;
    if (closed) return;
    if (result.path != file.path || await file.length() > attachmentLimit) {
      throw const FormatException();
    }
    final captured = await file.readAsBytes();
    if (!isLocalVideo(captured)) throw const FormatException();
    await camera!.dispose();
    camera = null;
    await preview();
  }

  Future<void> preview() async {
    if (closed) return;
    final controller = player = VideoPlayerController.file(file);
    await controller.initialize();
    final value = controller.value;
    if (value.duration <= Duration.zero ||
        value.duration > videoPlaybackLimit ||
        value.size.isEmpty ||
        value.size.longestSide > 1920) {
      throw const FormatException();
    }
  }

  void dismiss([Uint8List? result]) {
    if (!mounted || closed) return;
    final route = fullscreen;
    if (route?.isActive == true) route!.navigator!.removeRoute(route);
    if (!widget.inline && ModalRoute.of(context)?.isCurrent != true) return;
    closed = true;
    timer?.cancel();
    if (widget.inline) {
      widget.onClose!();
    } else {
      Navigator.pop(context, result);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      dismiss();
    }
  }

  @override
  void dispose() {
    closed = true;
    final route = fullscreen;
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator!.removeRoute(route);
      });
    }
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    unawaited(
      pending
          .then((_) async {
            try {
              if (recording && camera != null) {
                await CameraPlatform.instance.stopVideoRecording(
                  camera!.cameraId,
                );
              }
            } catch (_) {
            } finally {
              try {
                await camera?.dispose();
              } finally {
                try {
                  await player?.dispose();
                } finally {
                  if (await folder?.exists() == true) {
                    await folder!.delete(recursive: true);
                  }
                }
              }
            }
          })
          .catchError((Object _) {}),
    );
    super.dispose();
  }

  void openFullscreen(VideoPlayerController playback) {
    if (fullscreen != null || closed) return;
    final route = MaterialPageRoute<void>(
      builder: (ctx) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: Text(widget.tr('Видеосообщение', 'Video message')),
        ),
        bottomNavigationBar: SafeArea(
          child: ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: playback,
            builder: (context, v, _) => TextButton.icon(
              onPressed: () => perform(() => togglePlayback(playback)),
              icon: Icon(v.isPlaying ? Icons.pause : Icons.play_arrow),
              label: Text(
                v.isPlaying
                    ? widget.tr('Пауза', 'Pause')
                    : widget.tr('Смотреть', 'Play'),
              ),
            ),
          ),
        ),
        body: SafeArea(
          child: Center(
            child: AspectRatio(
              aspectRatio: playback.value.aspectRatio,
              child: VideoPlayer(playback),
            ),
          ),
        ),
      ),
    );
    fullscreen = route;
    unawaited(
      Navigator.of(context).push(route).whenComplete(() => fullscreen = null),
    );
  }

  Future<void> togglePlayback(VideoPlayerController playback) async {
    if (playback.value.isPlaying) {
      await playback.pause();
      return;
    }
    if (playback.value.position >= playback.value.duration) {
      await playback.seekTo(Duration.zero);
    }
    await playback.play();
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    final playback = player;
    final cam = camera;
    Widget surface = const Center(child: CircularProgressIndicator());
    if (playback != null && playback.value.isInitialized) {
      surface = FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: playback.value.size.width,
          height: playback.value.size.height,
          child: VideoPlayer(playback),
        ),
      );
    } else if (cam != null && cam.value.isInitialized) {
      surface = FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: cam.value.aspectRatio * 200,
          height: 200,
          child: CameraPreview(cam),
        ),
      );
    }
    final content = failed
        ? Text(
            tr(
              'Видео недоступно. Проверьте разрешения камеры и микрофона или выберите другой файл.',
              'Video unavailable. Check camera and microphone permissions or choose another file.',
            ),
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 184),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(4),
                        child: ClipOval(child: surface),
                      ),
                      if (playback != null && playback.value.isInitialized)
                        ValueListenableBuilder<VideoPlayerValue>(
                          valueListenable: playback,
                          builder: (_, value, _) => IgnorePointer(
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              value:
                                  (value.position.inMilliseconds /
                                          value.duration.inMilliseconds.clamp(
                                            1,
                                            14000,
                                          ))
                                      .clamp(0, 1),
                              semanticsLabel: tr(
                                'Позиция видео',
                                'Video progress',
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (recording)
                Text(
                  '${elapsed.elapsed.inSeconds.clamp(0, 12)} / 12 ${tr('с', 's')}',
                )
              else if (widget.received == null && playback == null)
                Text(tr('До 12 секунд · 4 МиБ', 'Up to 12 seconds · 4 MiB')),
              if (cam != null &&
                  cam.value.isInitialized &&
                  !recording &&
                  cameras.length > 1)
                IconButton(
                  tooltip: tr('Переключить камеру', 'Switch camera'),
                  onPressed: busy ? null : () => perform(switchCamera),
                  icon: const Icon(Icons.cameraswitch_outlined),
                ),
              if (recording && !pauseUnavailable)
                TextButton.icon(
                  onPressed: busy ? null : () => perform(togglePause),
                  icon: Icon(paused ? Icons.videocam_outlined : Icons.pause),
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
              if (playback != null && playback.value.isInitialized)
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: playback,
                  builder: (_, v, _) => Wrap(
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '${v.position.inSeconds.clamp(0, v.duration.inSeconds)}/${v.duration.inSeconds} ${tr('с', 's')}',
                      ),
                      IconButton(
                        tooltip: v.volume > 0
                            ? tr('Без звука', 'Mute')
                            : tr('Включить звук', 'Unmute'),
                        icon: Icon(
                          v.volume > 0
                              ? Icons.volume_up_outlined
                              : Icons.volume_off_outlined,
                        ),
                        onPressed: busy
                            ? null
                            : () => perform(
                                () => playback.setVolume(v.volume > 0 ? 0 : 1),
                              ),
                      ),
                      IconButton(
                        tooltip: tr('Во весь экран', 'Fullscreen'),
                        icon: const Icon(Icons.fullscreen),
                        onPressed: busy ? null : () => openFullscreen(playback),
                      ),
                    ],
                  ),
                ),
            ],
          );
    final actions = <Widget>[
      TextButton(onPressed: dismiss, child: Text(tr('Закрыть', 'Close'))),
      if (!failed && playback == null)
        FilledButton(
          onPressed: busy ? null : () => perform(recording ? stop : start),
          child: Text(
            recording ? tr('Стоп', 'Stop') : tr('Записать', 'Record'),
          ),
        ),
      if (!failed && playback != null && playback.value.isInitialized)
        ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: playback,
          builder: (_, v, _) => TextButton(
            onPressed: busy
                ? null
                : () => perform(() => togglePlayback(playback)),
            child: Text(
              v.isPlaying ? tr('Пауза', 'Pause') : tr('Смотреть', 'Play'),
            ),
          ),
        ),
      if (!failed && !busy && playback != null && widget.received == null)
        FilledButton(
          onPressed: () =>
              perform(() async => dismiss(await file.readAsBytes())),
          child: Text(tr('Отправить', 'Send')),
        ),
    ];
    if (widget.inline) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          content,
          Wrap(children: actions),
        ],
      );
    }
    return AlertDialog(
      title: Text(tr('Видеосообщение', 'Video message')),
      scrollable: true,
      content: content,
      actions: actions,
    );
  }
}
