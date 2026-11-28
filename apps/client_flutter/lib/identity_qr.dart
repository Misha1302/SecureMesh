import 'dart:async';
import 'dart:io';
import 'dart:typed_data' show Int8List, BytesBuilder;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zxing2/qrcode.dart' as qr;

const _prefix = 'securemesh:device:v1:';
final _fingerprint = RegExp(r'^[A-F0-9]{64}$');

String _profilePrefix(String endpoint) {
  final uri = Uri.tryParse(endpoint);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      endpoint.length > 320) {
    throw const FormatException();
  }
  return 'securemesh:profile:v1:${uri.origin}/@';
}

final _username = RegExp(r'^[a-z0-9_]{3,32}$');

class ProfileQr extends _QrPainter {
  ProfileQr(String endpoint, String username)
    : super(
        _username.hasMatch(username)
            ? _profilePrefix(endpoint) + username
            : throw const FormatException(),
      );
}

class DeviceQr extends _QrPainter {
  DeviceQr(String fingerprint)
    : super(_prefix + fingerprint.replaceAll(' ', ''));
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.code);
  final String code;
  late final matrix = qr.Encoder.encode(
    code,
    qr.ErrorCorrectionLevel.m,
  ).matrix!;

  @override
  void paint(Canvas canvas, Size size) {
    final count = matrix.width;
    final unit = size.shortestSide / (count + 8);
    canvas.drawColor(Colors.white, BlendMode.src);
    final ink = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (var row = 0; row < count; row++) {
      for (var col = 0; col < count; col++) {
        if (matrix.get(col, row) == 1) {
          canvas.drawRect(
            Rect.fromLTWH((col + 4) * unit, (row + 4) * unit, unit, unit),
            ink,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) => oldDelegate.code != code;
}

typedef _Frame = ({
  int width,
  int height,
  int stride,
  int step,
  Uint8List data,
  bool gray,
  String? profilePrefix,
});
String? _readCode(_Frame frame) {
  if (frame.width < 1 ||
      frame.height < 1 ||
      frame.width * frame.height > 4000000) {
    return null;
  }
  final gray = Int8List(frame.width * frame.height);
  for (var y = 0; y < frame.height; y++) {
    for (var x = 0; x < frame.width; x++) {
      final i = y * frame.stride + x * frame.step;
      gray[y * frame.width + x] = frame.gray
          ? frame.data[i]
          : (frame.data[i] + 2 * frame.data[i + 1] + frame.data[i + 2]) ~/ 4;
    }
  }
  final source = qr.RGBLuminanceSource.crop(
    gray,
    frame.width,
    frame.height,
    0,
    0,
    frame.width,
    frame.height,
  );
  try {
    final code = qr.QRCodeReader()
        .decode(qr.BinaryBitmap(qr.HybridBinarizer(source)))
        .text;
    final profilePrefix = frame.profilePrefix;
    if (profilePrefix != null) {
      if (!code.startsWith(profilePrefix)) return null;
      final name = code.substring(profilePrefix.length);
      return _username.hasMatch(name) ? name : null;
    }
    if (code.startsWith(_prefix)) {
      final value = code.substring(_prefix.length);
      if (_fingerprint.hasMatch(value)) return value;
    }
  } on qr.ReaderException {
    return null;
  }
  return null;
}

Future<String?> scanIdentityCode(
  BuildContext context,
  String Function(String, String) tr,
) => _scanCode(context, tr, null);

Future<String?> scanProfileCode(
  BuildContext context,
  String Function(String, String) tr,
  String endpoint,
) => _scanCode(context, tr, _profilePrefix(endpoint));

Future<String?> _scanCode(
  BuildContext context,
  String Function(String, String) tr,
  String? profilePrefix,
) async {
  if (Platform.isAndroid || Platform.isIOS) {
    return showDialog<String>(
      context: context,
      builder: (_) => _ScanCamera(tr, profilePrefix),
    );
  }
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(
        label: 'QR',
        extensions: ['png', 'jpg', 'jpeg'],
        uniformTypeIdentifiers: ['public.png', 'public.jpeg'],
      ),
    ],
  );
  if (file == null) return null;
  return _readImage(file, profilePrefix);
}

Future<String> readIdentityImage(XFile file) => _readImage(file, null);

Future<String> readProfileImage(XFile file, String endpoint) =>
    _readImage(file, _profilePrefix(endpoint));

Future<String> _readImage(XFile file, String? profilePrefix) async {
  final bytes = BytesBuilder(copy: false);
  await for (final part in file.openRead()) {
    if (bytes.length + part.length > 8 * 1024 * 1024) {
      throw const FormatException();
    }
    bytes.add(part);
  }
  final buf = await ui.ImmutableBuffer.fromUint8List(bytes.takeBytes());
  try {
    final desc = await ui.ImageDescriptor.encoded(buf);
    try {
      if (desc.width * desc.height > 16000000) throw const FormatException();
      final scale = math.min(1.0, 1200 / math.max(desc.width, desc.height));
      final codec = await desc.instantiateCodec(
        targetWidth: math.max(1, (desc.width * scale).round()),
        targetHeight: math.max(1, (desc.height * scale).round()),
      );
      try {
        final image = (await codec.getNextFrame()).image;
        try {
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          if (data == null) throw const FormatException();
          return await compute<_Frame, String?>(_readCode, (
                width: image.width,
                height: image.height,
                stride: image.width * 4,
                step: 4,
                data: data.buffer.asUint8List(
                  data.offsetInBytes,
                  data.lengthInBytes,
                ),
                gray: false,
                profilePrefix: profilePrefix,
              )) ??
              (throw const FormatException());
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } finally {
      desc.dispose();
    }
  } finally {
    buf.dispose();
  }
}

class _ScanCamera extends StatefulWidget {
  const _ScanCamera(this.tr, this.profilePrefix);
  final String? profilePrefix;
  final String Function(String, String) tr;
  @override
  State<_ScanCamera> createState() => _ScanCameraState();
}

class _ScanCameraState extends State<_ScanCamera> with WidgetsBindingObserver {
  CameraController? camera;
  bool failed = false, decoding = false, closed = false;
  DateTime next = DateTime.fromMillisecondsSinceEpoch(0);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(start());
  }

  Future<void> start() async {
    try {
      final cameras = await availableCameras();
      if (closed || cameras.isEmpty) throw StateError('Camera unavailable');
      final c = CameraController(
        cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cameras.first,
        ),
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isIOS
            ? ImageFormatGroup.bgra8888
            : ImageFormatGroup.yuv420,
      );
      camera = c;
      await c.initialize();
      if (closed) return;
      setState(() {});
      await c.startImageStream((image) async {
        if (closed ||
            decoding ||
            DateTime.now().isBefore(next) ||
            image.planes.isEmpty) {
          return;
        }
        decoding = true;
        next = DateTime.now().add(const Duration(milliseconds: 350));
        try {
          final plane = image.planes.first;
          final gray = image.format.group != ImageFormatGroup.bgra8888;
          final code = await compute<_Frame, String?>(_readCode, (
            width: image.width,
            height: image.height,
            stride: plane.bytesPerRow,
            step: gray ? (plane.bytesPerPixel ?? 1) : 4,
            data: plane.bytes,
            gray: gray,
            profilePrefix: widget.profilePrefix,
          ));
          if (code != null &&
              mounted &&
              !closed &&
              ModalRoute.of(context)?.isCurrent == true) {
            closed = true;
            Navigator.pop(context, code);
          }
        } catch (_) {
          if (mounted && !closed) setState(() => failed = true);
        } finally {
          decoding = false;
        }
      });
    } catch (_) {
      if (mounted && !closed) setState(() => failed = true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden) &&
        !closed &&
        ModalRoute.of(context)?.isCurrent == true) {
      closed = true;
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    closed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(camera?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.profilePrefix == null
          ? widget.tr('Сканировать код устройства', 'Scan device code')
          : widget.tr('Сканировать QR-код профиля', 'Scan profile QR code'),
    ),
    content: failed
        ? Text(
            widget.tr(
              'Камера недоступна. Введите код вручную.',
              'Camera unavailable. Enter the code manually.',
            ),
          )
        : camera?.value.isInitialized == true
        ? AspectRatio(aspectRatio: 1, child: CameraPreview(camera!))
        : const SizedBox(
            height: 80,
            child: Center(child: CircularProgressIndicator()),
          ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(widget.tr('Закрыть', 'Close')),
      ),
    ],
  );
}
