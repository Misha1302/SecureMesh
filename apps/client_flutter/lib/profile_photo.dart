import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';

import 'display_name.dart';
import 'transport.dart';

const photoSide = 48;
const _rgbSize = photoSide * photoSide * 3;
const _maxFileSize = 8 * 1024 * 1024;

Future<Uint8List> readPhoto(XFile file) async {
  if (await file.length() > _maxFileSize) throw const FormatException();
  final data = BytesBuilder(copy: false);
  await for (final part in file.openRead()) {
    if (data.length + part.length > _maxFileSize) throw const FormatException();
    data.add(part);
  }
  return makeThumbnail(data.takeBytes());
}

// Decode only the selected local file. Scale and center-crop locally, carrying
// plain RGB pixels across the network. Embedded metadata never leaves the client.
Future<Uint8List> makeThumbnail(Uint8List bytes) async {
  if (bytes.isEmpty || bytes.length > _maxFileSize) {
    throw const FormatException();
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      final width = descriptor.width;
      final height = descriptor.height;
      if (width <= 0 || height <= 0 || width * height > 16000000) {
        throw const FormatException();
      }
      final scale = math.min(1.0, 512 / math.max(width, height));
      final codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (width * scale).round()),
        targetHeight: math.max(1, (height * scale).round()),
      );
      try {
        final frame = await codec.getNextFrame();
        final image = frame.image;
        try {
          final side = math.min(image.width, image.height).toDouble();
          final recorder = ui.PictureRecorder();
          final canvas = ui.Canvas(recorder);
          const target = ui.Rect.fromLTWH(0, 0, 48, 48);
          canvas.drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
          canvas.drawImageRect(
            image,
            ui.Rect.fromLTWH(
              (image.width - side) / 2,
              (image.height - side) / 2,
              side,
              side,
            ),
            target,
            ui.Paint()..filterQuality = ui.FilterQuality.medium,
          );
          final picture = recorder.endRecording();
          try {
            final tile = await picture.toImage(photoSide, photoSide);
            try {
              final rgba = await tile.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              );
              if (rgba == null) throw const FormatException();
              final rgb = Uint8List(_rgbSize);
              for (var pixel = 0; pixel < photoSide * photoSide; pixel++) {
                for (var channel = 0; channel < 3; channel++) {
                  rgb[pixel * 3 + channel] = rgba.getUint8(pixel * 4 + channel);
                }
              }
              return rgb;
            } finally {
              tile.dispose();
            }
          } finally {
            picture.dispose();
          }
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}

Uint8List? photoPixels(Object? value) {
  if (value == null) return null;
  if (value is! String || value.length != _rgbSize * 4 ~/ 3) {
    throw const FormatException();
  }
  final decoded = base64Decode(value);
  if (decoded.length != _rgbSize) throw const FormatException();
  return decoded;
}

// Construct a fixed-format, bounded BMP locally. Received data can affect
// only pixels, never decoder dimensions, compression mode or file offsets.
Uint8List photoBitmap(Uint8List rgb) {
  if (rgb.length != _rgbSize) throw const FormatException();
  final bytes = Uint8List(54 + _rgbSize);
  final h = ByteData.sublistView(bytes);
  bytes[0] = 0x42;
  bytes[1] = 0x4d;
  h.setUint32(2, bytes.length, Endian.little);
  h.setUint32(10, 54, Endian.little);
  h.setUint32(14, 40, Endian.little);
  h.setInt32(18, photoSide, Endian.little);
  h.setInt32(22, -photoSide, Endian.little);
  h.setUint16(26, 1, Endian.little);
  h.setUint16(28, 24, Endian.little);
  h.setUint32(34, _rgbSize, Endian.little);
  for (var i = 0; i < rgb.length; i += 3) {
    bytes[54 + i] = rgb[i + 2];
    bytes[55 + i] = rgb[i + 1];
    bytes[56 + i] = rgb[i];
  }
  return bytes;
}

final _uuid = RegExp(
  r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$',
);

String? peerPhotoRoute(Object? group, Object? version) {
  if (group is! String ||
      version is! String ||
      !_uuid.hasMatch(group) ||
      !_uuid.hasMatch(version)) {
    return null;
  }
  return '/v1/conversations/$group/photo/$version';
}

class PeerAvatar extends StatefulWidget {
  const PeerAvatar({
    super.key,
    required this.route,
    required this.fetch,
    required this.username,
  });
  final String? route;
  final HttpsRequest fetch;
  final String username;
  @override
  State<PeerAvatar> createState() => _PeerAvatarState();
}

class _PeerAvatarState extends State<PeerAvatar> {
  Future<Uint8List?>? image;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(PeerAvatar old) {
    super.didUpdateWidget(old);
    if (old.route != widget.route) load();
  }

  void load() {
    final route = widget.route;
    image = route == null
        ? null
        : widget.fetch(route).then((result) {
            final pixels = photoPixels((result as Map)['pixels']);
            return pixels == null ? null : photoBitmap(pixels);
          });
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    key: ValueKey(widget.route),
    future: image,
    builder: (context, state) {
      final data = state.data;
      return CircleAvatar(
        foregroundImage: data == null ? null : MemoryImage(data),
        child: Text(
          widget.username.isEmpty
              ? '?'
              : widget.username.characters.first.toUpperCase(),
        ),
      );
    },
  );
}

class ProfilePhotoEditor extends StatefulWidget {
  const ProfilePhotoEditor({
    super.key,
    required this.api,
    required this.russian,
    this.pick,
  });
  final DisplayNameApi api;
  final bool russian;
  final Future<XFile?> Function()? pick;
  @override
  State<ProfilePhotoEditor> createState() => _ProfilePhotoEditorState();
}

class _ProfilePhotoEditorState extends State<ProfilePhotoEditor> {
  Uint8List? pixels;
  Uint8List? preview;
  bool busy = true, loaded = false, changed = false;
  String? error;
  String tr(String ru, String en) => widget.russian ? ru : en;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final me = await widget.api('/v1/users/me/photo') as Map;
      final current = photoPixels(me['pixels']);
      if (!mounted) return;
      pixels = current;
      preview = current == null ? null : photoBitmap(current);
      loaded = true;
    } catch (_) {
      if (mounted) {
        error = tr('Не удалось загрузить фото.', 'Could not load the photo.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> choose() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      const types = XTypeGroup(
        label: 'JPEG / PNG',
        extensions: ['jpg', 'jpeg', 'png'],
        mimeTypes: ['image/jpeg', 'image/png'],
        uniformTypeIdentifiers: ['public.jpeg', 'public.png'],
      );
      final file =
          await (widget.pick?.call() ?? openFile(acceptedTypeGroups: [types]));
      if (file == null || !mounted) return;
      final data = await readPhoto(file);
      if (!mounted) return;
      pixels = data;
      preview = photoBitmap(data);
      changed = true;
    } catch (_) {
      if (mounted) {
        error = tr(
          'Выберите JPEG или PNG до 8 МиБ и 16 мегапикселей.',
          'Choose a JPEG or PNG up to 8 MiB and 16 megapixels.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.api(
        '/v1/users/me/photo',
        method: 'PUT',
        data: {'pixels': pixels == null ? null : base64Encode(pixels!)},
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error = tr('Не удалось сохранить фото.', 'Could not save the photo.');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('Фото профиля', 'Profile photo')),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) const LinearProgressIndicator(),
          if (loaded) ...[
            CircleAvatar(
              radius: 32,
              foregroundImage: preview == null ? null : MemoryImage(preview!),
              child: const Icon(Icons.person_outline),
            ),
            const SizedBox(height: 12),
            Text(
              tr(
                'После сохранения сервер и участники ваших личных чатов смогут видеть миниатюру. Исходный файл останется на устройстве.',
                'Saving shares the thumbnail with your server and existing DM peers. The original file stays on this device.',
              ),
            ),
            TextButton(
              onPressed: busy ? null : choose,
              child: Text(tr('Выбрать фотографию', 'Choose a photo')),
            ),
            if (pixels != null)
              TextButton(
                onPressed: busy
                    ? null
                    : () => setState(() {
                        pixels = null;
                        preview = null;
                        changed = true;
                      }),
                child: Text(tr('Убрать фото', 'Remove photo')),
              ),
          ],
          if (error != null) Semantics(liveRegion: true, child: Text(error!)),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr('Закрыть', 'Close')),
      ),
      if (!busy && !loaded)
        TextButton(onPressed: load, child: Text(tr('Повторить', 'Retry'))),
      if (loaded)
        FilledButton(
          onPressed: busy || !changed ? null : save,
          child: Text(tr('Сохранить', 'Save')),
        ),
    ],
  );
}
