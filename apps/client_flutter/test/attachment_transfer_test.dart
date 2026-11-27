import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:securemesh_client/attachment_transfer.dart';

class _TestBlobs implements BlobTransport {
  final ciphertext = Uint8List.fromList(List.generate(22, (i) => i));
  Completer<void>? waitOnGet;
  int puts = 0, gets = 0;
  bool failNextPut = false, closed = false;
  @override
  Future<void> put(
    String id,
    Uint8List bytes,
    void Function(double) progress,
  ) async {
    puts++;
    expect(id, 'opaque');
    expect(bytes, ciphertext);
    if (failNextPut) {
      failNextPut = false;
      throw StateError('offline');
    }
    progress(1);
  }

  @override
  Future<Uint8List> get(
    String message,
    String id,
    int size,
    void Function(double) progress,
  ) async {
    gets++;
    expect(size, 22);
    await waitOnGet?.future;
    progress(1);
    return ciphertext;
  }

  @override
  void close() {
    closed = true;
  }
}

void main() {
  test('batch queues files separately with a private first caption and reports unfinished files', () async {
    final names = <String>[];
    final captions = <Object?>[];
    final uploads = PrivateAttachments(
      'group',
      (op, args) async {
        if (op == 'attachment_pending')
          return {
            'uploads': [...names],
          };
        names.add(args['name'] as String);
        captions.add(args['caption']);
        return {};
      },
      _TestBlobs(),
      () {},
    );
    XFile file(String path, List<int> data) =>
        XFile.fromData(Uint8List.fromList(data), path: path);
    await uploads.stageSelection(
      () async => (
        files: [
          file('a', [1]),
          file('b', [2]),
          file('empty', []),
          file('c', [3]),
        ],
        caption: 'Привет',
      ),
    );
    expect(names, ['a', 'b']);
    expect(captions, ['Привет', null]);
    expect(uploads.selectionRemaining, 2);
    expect(uploads.status, 'size');
    uploads.dispose();
  });

  test('staging is offline, weak automatic upload waits, manual retry commits only after PUT', () async {
    final blobs = _TestBlobs();
    final pending = <Map<String, dynamic>>[];
    var committed = 0;
    final ops = <String>[];
    final upload = PrivateAttachments(
      'group',
      (op, args) async {
        ops.add(op);
        expect(args['group'], 'group');
        switch (op) {
          case 'attachment_prepare':
            expect(base64Decode(args['data'] as String), utf8.encode('secret'));
            expect(args['name'], 'safe.txt');
            pending.add({
              'id': args['id'],
              'blobId': 'opaque',
              'ciphertextBytes': 22,
            });
            return {};
          case 'attachment_pending':
            return {
              'uploads': [...pending],
            };
          case 'attachment_ciphertext':
            return {'ciphertext': base64Encode(blobs.ciphertext)};
          case 'attachment_queue':
            expect(blobs.puts, 2);
            pending.clear();
            return {};
          default:
            throw StateError(op);
        }
      },
      blobs,
      () => committed++,
    );
    await upload.stage(
      () async => XFile.fromData(
        Uint8List.fromList(utf8.encode('secret')),
        path: 'safe.txt',
      ),
    );
    expect(upload.pending.length, 1);
    await upload.resume(explicit: false, weak: true);
    expect(blobs.puts, 0);
    blobs.failNextPut = true;
    await upload.resume(explicit: true, weak: true);
    expect(committed, 0);
    expect(upload.pending.length, 1);
    await upload.resume(explicit: true, weak: true);
    expect(committed, 1);
    expect(upload.status, isNull);
    expect(upload.pending, isEmpty);
    expect(ops.where((x) => x == 'attachment_queue'), hasLength(1));
    upload.dispose();
  });

  test(
    'failed verification or closed session never exports plaintext',
    () async {
      final blobs = _TestBlobs();
      var exports = 0, rejects = true;
      final transfer = PrivateAttachments(
        'g',
        (op, args) async {
          if (op == 'attachment_download_reset') return {};
          expect(op, 'attachment_open');
          if (rejects) throw StateError('authentication failed');
          return {
            'name': '../../a.txt',
            'data': base64Encode(utf8.encode('secret')),
            'size': 6,
          };
        },
        blobs,
        () => fail('unexpected queue'),
      );
      final metadata = {'blobId': 'opaque', 'size': 6};
      Future<bool> save(String name, Uint8List bytes) async {
        expect(name, 'a.txt');
        expect(utf8.decode(bytes), 'secret');
        exports++;
        return true;
      }

      await transfer.download('id', metadata, save);
      expect(exports, 0);
      expect(transfer.status, 'failed');
      rejects = false;
      await transfer.download('id', metadata, save);
      expect(exports, 1);
      blobs.waitOnGet = Completer<void>();
      final pending = transfer.download('id', metadata, save);
      transfer.dispose();
      blobs.waitOnGet!.complete();
      await pending;
      expect(exports, 1);
      expect(blobs.closed, true);
    },
  );

  test(
    'oversized input is rejected before upload; suggested names stay local',
    () async {
      final blobs = _TestBlobs();
      final transfer = PrivateAttachments(
        'g',
        (op, args) async => throw StateError('Unexpected store operation'),
        blobs,
        () => fail('unexpected queue'),
      );
      await transfer.stage(
        () async =>
            XFile.fromData(Uint8List(attachmentLimit + 1), path: 'large'),
      );
      expect(transfer.status, 'size');
      expect(blobs.puts, 0);
      expect(attachmentName(r'C:\private\..\CON.txt'), 'attachment');
      expect(attachmentName('../../проект.pdf'), 'проект.pdf');
      expect(attachmentName('file\u0085name.txt'), 'file_name.txt');
      transfer.dispose();
    },
  );
}
