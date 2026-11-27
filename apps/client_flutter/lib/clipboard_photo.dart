import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import 'attachment_transfer.dart';

bool get clipboardPhotoSupported =>
    Platform.isAndroid || Platform.isLinux || Platform.isWindows;

const clipboardPhotoChannel = MethodChannel('securemesh/clipboard-photo');

/// Reads encoded pixels only, on explicit request. Re-encode the preview so
/// the outgoing photo exactly matches it and contains no sender EXIF or paths.
Future<Uint8List?> readClipboardPhoto() async {
  final bytes = await clipboardPhotoChannel.invokeMethod<Uint8List>('read');
  if (bytes == null || bytes.isEmpty) return null;
  if (bytes.length > attachmentLimit) throw const FormatException('SIZE');
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  final png =
      bytes.length >= signature.length &&
      Iterable<int>.generate(signature.length)
          .every((i) => bytes[i] == signature[i]);
  final jpeg =
      bytes.length >= 3 &&
      bytes[0] == 255 &&
      bytes[1] == 216 &&
      bytes[2] == 255;
  if (!png && !jpeg) throw const FormatException('IMAGE');
  final image = await attachmentPreview(bytes);
  try {
    final encoded = await image.toByteData(format: ui.ImageByteFormat.png);
    if (encoded == null || encoded.lengthInBytes > attachmentLimit) {
      throw const FormatException('SIZE');
    }
    return encoded.buffer.asUint8List(
      encoded.offsetInBytes,
      encoded.lengthInBytes,
    );
  } finally {
    image.dispose();
  }
}
