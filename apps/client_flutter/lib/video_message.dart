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
    this.listCameras = availableCameras,
  });
  final Future<List<CameraDescription>> Function() listCameras;
  final String Function(String, String) tr;
  final Uint8List? received;
  @override
  State<VideoMessageDialog> createState() => _VideoMessageDialogState();
}

class _VideoMessageDialogState extends State<VideoMessageDialog>
    with WidgetsBindingObserver {
  CameraController? camera;
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
      final cameras = received == null
          ? await widget.listCameras()
          : const <CameraDescription>[];
      if (closed) return;
      folder = await (await VideoScratch.root()).createTemp('clip-');
      if (closed) return;
      if (received != null) {
        if (!isLocalVideo(received)) throw const FormatException();
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
    if (!closed) timer = Timer(videoRecordLimit, () => perform(stop));
  }

  Future<void> stop() async {
    timer?.cancel();
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
    if (!mounted || closed || ModalRoute.of(context)?.isCurrent != true) return;
    closed = true;
    timer?.cancel();
    Navigator.pop(context, result);
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
    return AlertDialog(
      title: Text(tr('Видеосообщение', 'Video message')),
      content: failed
          ? Text(
              tr(
                'Видео недоступно. Проверьте разрешения камеры и микрофона или выберите другой файл.',
                'Video unavailable. Check camera and microphone permissions or choose another file.',
              ),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: 184,
                  child: ClipOval(child: surface),
                ),
                if (widget.received == null)
                  Text(tr('До 12 секунд · 4 МиБ', 'Up to 12 seconds · 4 MiB')),
              ],
            ),
      actions: [
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
                  : () => perform(() async {
                      if (v.isPlaying) {
                        await playback.pause();
                      } else {
                        if (v.position >= v.duration) {
                          await playback.seekTo(Duration.zero);
                        }
                        await playback.play();
                      }
                    }),
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
      ],
    );
  }
}
