import 'dart:async';

import 'transport.dart';

typedef CryptoCommand = Future<Map<String, dynamic>> Function(
  String, [
  Map<String, dynamic>,
]);

class DeliveryProgress {
  DeliveryProgress(this.sent, this.received, this.queued);
  final int sent, received, queued;
  Duration get delay => Duration(
    milliseconds: queued > 0
        ? 50
        : sent > 0 || received > 0
        ? 250
        : 3000,
  );
}

/// The native UI and executable network tests share this exact delivery cycle.
/// No timer owns message durability: the encrypted store owns outbox and cursor.
class NativeDelivery {
  NativeDelivery({required this.crypto, required this.transport});
  final CryptoCommand crypto;
  final MeshTransport transport;
  Future<void>? _receipt;
  final Map<String, int> _acknowledged = {};
  Object? receiptError;
  bool _closed = false, _busy = false;
  void close() {
    _closed = true;
  }

  Future<DeliveryProgress> tick(String group) async {
    if (_closed || _busy) throw StateError('DELIVERY_NOT_AVAILABLE');
    _busy = true;
    try {
      final pending = (await crypto('outbox'))['messages'] as List;
      // Drain earlier application messages before a control commit. Control
      // epochs are never raced with old-epoch application writes over HTTPS.
      final batch = <Map<String, dynamic>>[];
      for (final message in pending.take(3)) {
        if (message['kind'] != 1) {
          if (batch.isEmpty) {
            batch.add(Map<String, dynamic>.from(message as Map));
          }
          break;
        }
        batch.add(Map<String, dynamic>.from(message as Map));
      }
      var received = 0;
      final sending = batch.map((message) async {
        final ack = await transport.send(message);
        if (ack['durable'] != true) throw StateError('DURABLE_ACK_REQUIRED');
        await crypto('saved', {
          'group': message['group'],
          'id': message['id'],
          'seq': ack['serverSequence'],
        });
      });
      final pulling = () async {
        var cursor =
            (await crypto('cursor', {'group': group}))['cursor'] as String;
        for (var pages = 0; pages < 10; pages++) {
          Map<String, dynamic> page;
          try {
            page = await transport.sync(group, cursor);
          } on ApiFailure catch (failure) {
            if (failure.code == 'INVALID_CURSOR' && cursor.isNotEmpty) {
              cursor = '';
              continue;
            }
            rethrow;
          }
          final messages = page['messages'] as List;
          for (var i = 0; i < messages.length; i++) {
            final message = messages[i] as Map;
            await crypto('ingest', {
              'group': group,
              'id': message['clientMessageId'],
              'sender': message['senderDeviceId'],
              'seq': message['serverSequence'],
              'epoch': message['mlsEpoch'],
              'kind': message['envelopeKind'],
              'ciphertext': message['ciphertext'],
              'digest': message['ciphertextSha256'],
              'cursor': i == messages.length - 1 ? page['nextCursor'] : '',
            });
          }
          received += messages.length;
          cursor = page['nextCursor'] as String;
          if (page['hasMore'] != true) break;
        }
        final seq = (await crypto('cursor', {'group': group}))['seq'] as int;
        _scheduleReceipt(group, seq);
      }();
      await Future.wait<void>([...sending, pulling]);
      final remaining = (await crypto('outbox'))['messages'] as List;
      return DeliveryProgress(batch.length, received, remaining.length);
    } finally {
      _busy = false;
    }
  }

  void _scheduleReceipt(String group, int seq) {
    if (_closed || _receipt != null || seq <= (_acknowledged[group] ?? 0)) {
      return;
    }
    // Receipt loss does not invalidate an already committed local inbox. Keep
    // one pending receipt, expose failure and retry the latest durable cursor.
    _receipt = transport
        .ack(group, seq)
        .then((_) {
          _acknowledged[group] = seq;
          receiptError = null;
        })
        .catchError((Object error) {
          receiptError = error;
        })
        .whenComplete(() => _receipt = null);
  }
}
