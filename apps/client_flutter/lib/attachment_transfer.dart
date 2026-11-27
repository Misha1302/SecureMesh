import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'conversation_drafts.dart';
import 'local_client.dart';
import 'attachment_transport.dart';
export 'attachment_transport.dart';

const _tagLength = 16;

String attachmentName(String untrusted) {
  final name = untrusted
      .split(RegExp(r'[/\\]'))
      .last
      .replaceAll(
        RegExp(r'[\x00-\x1f\x7f-\x9f<>:"|?*\u202a-\u202e\u2066-\u2069]'),
        '_',
      )
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (name.isEmpty ||
      RegExp(
        r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)',
        caseSensitive: false,
      ).hasMatch(name)) {
    return 'attachment';
  }
  final chars = <int>[];
  var byteCount = 0;
  for (final rune in name.runes) {
    byteCount += utf8.encode(String.fromCharCode(rune)).length;
    if (byteCount > 120) break;
    chars.add(rune);
  }
  return String.fromCharCodes(chars);
}

Future<Uint8List> readAttachment(XFile input) async {
  final expected = await input.length();
  if (expected < 1 || expected > attachmentLimit) {
    throw const FormatException('SIZE');
  }
  final bytes = BytesBuilder(copy: false);
  await for (final part in input.openRead()) {
    if (bytes.length + part.length > expected) {
      throw const FormatException('SIZE');
    }
    bytes.add(part);
  }
  if (bytes.length != expected) throw const FormatException('SIZE');
  return bytes.takeBytes();
}

class PrivateAttachments extends ChangeNotifier {
  PrivateAttachments(this.group, this.crypto, this.blobs, this.queued);
  final String group;
  final DraftCommand crypto;
  final BlobTransport blobs;
  final VoidCallback queued;
  bool _closed = false;
  bool busy = false;
  double? progress;
  String? status;
  List<dynamic> pending = [];
  DateTime nextAttempt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _loaded = false;

  void _active() {
    if (_closed) throw StateError('Attachment session closed');
  }

  void _update() {
    if (!_closed) notifyListeners();
  }

  void _progress(double value) {
    _active();
    if (progress == null || value - progress! >= .02 || value == 1) {
      progress = value;
      _update();
    }
  }

  Future<void> _load() async {
    _active();
    final r = await crypto('attachment_pending', {'group': group});
    _active();
    pending = r['uploads'] as List<dynamic>;
    _loaded = true;
  }

  Future<void> load() => _run(_load);
  Future<void> _run(Future<void> Function() action) async {
    if (_closed || busy) return;
    busy = true;
    status = null;
    progress = null;
    _update();
    try {
      await action();
    } catch (e) {
      if (!_closed) {
        status = e is FormatException && e.message == 'SIZE'
            ? 'size'
            : 'failed';
      }
      nextAttempt = DateTime.now().add(const Duration(seconds: 30));
    } finally {
      busy = false;
      progress = null;
      _update();
    }
  }

  Future<void> stage(Future<XFile?> Function() pick) => _run(() async {
    final file = await pick();
    _active();
    if (file == null) return;
    final data = await readAttachment(file);
    _active();
    final name = attachmentName(file.name);
    final isPhoto = RegExp(
      r'\.(png|jpg|jpeg|webp)$',
      caseSensitive: false,
    ).hasMatch(name);
    await _stageBytes(data, name, isPhoto ? 'photo' : 'file');
  });

  Future<void> stageMedia(
    String media,
    String name,
    Future<Uint8List?> Function() pick,
  ) => _run(() async {
    final data = await pick();
    _active();
    if (data != null) await _stageBytes(data, attachmentName(name), media);
  });

  Future<void> _stageBytes(Uint8List data, String name, String media) async {
    if (data.isEmpty || data.length > attachmentLimit) {
      throw const FormatException('SIZE');
    }
    await crypto('attachment_prepare', {
      'group': group,
      'id': newUuid(),
      'name': name,
      'media': media,
      'data': base64Encode(data),
    });
    await _load();
    status = 'staged';
  }

  Future<void> resume({required bool explicit, required bool weak}) async {
    if (busy ||
        _closed ||
        (!explicit && (weak || DateTime.now().isBefore(nextAttempt)))) {
      return;
    }
    if (!explicit && _loaded && pending.isEmpty) return;
    await _run(() async {
      if (!_loaded) await _load();
      if (pending.isEmpty) return;
      final entry = pending.first;
      final id = entry['id'] as String;
      final args = {'group': group, 'id': id};
      final result = await crypto('attachment_ciphertext', args);
      _active();
      final bytes = base64Decode(result['ciphertext'] as String);
      if (bytes.length != entry['ciphertextBytes'] ||
          bytes.length > attachmentLimit + _tagLength) {
        throw const FormatException('SIZE');
      }
      status = 'upload';
      progress = 0;
      _update();
      await blobs.put(entry['blobId'] as String, bytes, _progress);
      _active();
      await crypto('attachment_queue', args);
      _active();
      pending = pending.where((e) => e['id'] != id).toList();
      queued();
    });
  }

  Future<void> cancelFirst() => _run(() async {
    if (pending.isEmpty) return;
    await crypto('attachment_cancel', {
      'group': group,
      'id': pending.first['id'],
    });
    await _load();
  });
  Future<void> download(
    String id,
    Map<String, dynamic> metadata,
    Future<bool> Function(String, Uint8List) save,
  ) => _run(() async {
    final size = metadata['size'] as int;
    if (size < 1 || size > attachmentLimit) throw const FormatException('SIZE');
    status = 'download';
    progress = 0;
    _update();
    final cipher = await blobs.get(
      id,
      metadata['blobId'] as String,
      size + _tagLength,
      _progress,
    );
    _active();
    if (cipher.length != size + _tagLength) throw const FormatException('SIZE');
    late final Map<String, dynamic> result;
    try {
      result = await crypto('attachment_open', {
        'group': group,
        'id': id,
        'ciphertext': base64Encode(cipher),
      });
    } catch (_) {
      _active();
      await crypto('attachment_download_reset', {'group': group, 'id': id});
      rethrow;
    }
    _active();
    final plain = base64Decode(result['data'] as String);
    if (plain.length != size || result['size'] != size) {
      throw const FormatException('SIZE');
    }
    status = await save(attachmentName(result['name'] as String), plain)
        ? 'saved'
        : null;
  });

  @override
  void dispose() {
    _closed = true;
    blobs.close();
    super.dispose();
  }
}

Future<bool> exportAttachment(String name, Uint8List bytes) async {
  if (Platform.isIOS || Platform.isAndroid) {
    return await const MethodChannel('securemesh/attachment-export')
            .invokeMethod<bool>('save', {'name': name, 'bytes': bytes}) ??
        false;
  }
  final dest = await getSaveLocation(suggestedName: name);
  if (dest == null) return false;
  // A temp sibling prevents a failed/partial export from replacing an existing file.
  final target = File(dest.path);
  final tempDir = await target.parent.createTemp('.securemesh-export-');
  try {
    final tmp = File('${tempDir.path}/file');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path);
  } finally {
    await tempDir.delete(recursive: true);
  }
  return true;
}

/// Decode only after MLS/AEAD verification and explicit preview. Reject images
/// whose encoded dimensions would require excessive memory, even if compressed.
Future<ui.Image> attachmentPreview(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      if (descriptor.width < 1 ||
          descriptor.height < 1 ||
          descriptor.width * descriptor.height > 16000000) {
        throw const FormatException('IMAGE');
      }
      final scale = math.min(
        1.0,
        960 / math.max(descriptor.width, descriptor.height),
      );
      final codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * scale).round()),
        targetHeight: math.max(1, (descriptor.height * scale).round()),
      );
      try {
        return (await codec.getNextFrame()).image;
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
