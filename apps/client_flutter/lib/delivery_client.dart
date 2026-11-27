import 'dart:async';

import 'linux_notifications.dart' show isNewIncomingText;
import 'transport.dart';

typedef CryptoCommand = Future<Map<String, dynamic>> Function(
  String, [
  Map<String, dynamic>,
]);

class DeliveryProgress {
  DeliveryProgress(
    this.sent,
    this.received,
    this.queued, {
    this.active = false,
    this.connected = false,
    this.weak = false,
  });
  final int sent, received, queued;
  final bool active;
  final bool connected, weak;
  Duration get delay => Duration(
    milliseconds: queued > 0
        ? 50
        : active || sent > 0 || received > 0
        ? 250
        : 3000,
  );
}

/// The native UI and executable network tests share this exact delivery cycle.
/// No timer owns message durability: the encrypted store owns outbox and cursor.
class NativeDelivery {
  NativeDelivery({
    required this.crypto,
    required this.transport,
    this.onIncomingText,
    this.onCallSignal,
  });
  final void Function()? onIncomingText;
  final void Function(String group)? onCallSignal;
  final CryptoCommand crypto;
  final MeshTransport transport;
  Future<void>? _receipt;
  final Map<String, int> _peerProcessed = {};
  final Map<String, int> _acknowledged = {};
  final Map<String, Future<void>> _sends = {};
  Future<void>? _pull;
  String? _lastListedGroup;
  Object? _error;
  StackTrace? _errorStack;
  int _sent = 0, _received = 0;
  bool _connected = false, _weak = false;
  Object? receiptError;
  bool _closed = false, _busy = false;
  void close() {
    _closed = true;
  }

  Future<DeliveryProgress> tick(
    String group, {
    List<String> listedGroups = const [],
  }) async {
    if (_closed || _busy) throw StateError('DELIVERY_NOT_AVAILABLE');
    _busy = true;
    try {
      if (_error != null) {
        final error = _error!, stack = _errorStack!;
        _error = null;
        _errorStack = null;
        Error.throwWithStackTrace(error, stack);
      }
      final pending =
          (await crypto('outbox', {'dispatch': true}))['messages'] as List;
      // Refill available write slots independently of a slow sync or another
      // write's ACK. Waiting for a whole batch makes one TCP retransmission
      // stall all future writes and builds an unbounded queue on 2G.
      for (final raw in pending) {
        final message = Map<String, dynamic>.from(raw as Map);
        final key = '${message['group']}/${message['id']}';
        // Control epochs remain serial barriers. Never overtake earlier
        // application writes, including ones still awaiting durable ACKs.
        if (message['kind'] != 1) {
          if (_sends.isEmpty) _startSend(key, message);
          break;
        }
        if (_sends.containsKey(key)) continue;
        if (_sends.length >= 3) break;
        _startSend(key, message);
      }
      if (_pull == null) {
        var next = group;
        if (listedGroups.isNotEmpty) {
          final previous = listedGroups.indexOf(_lastListedGroup ?? '');
          next = listedGroups[(previous + 1) % listedGroups.length];
          _lastListedGroup = next;
        }
        _pull = _pullMessages(next)
            .catchError(_rememberError)
            .whenComplete(() => _pull = null);
      }
      await Future.any<void>([
        ..._sends.values,
        ?_pull,
        Future<void>.delayed(const Duration(milliseconds: 250)),
      ]);
      final sent = _sent, received = _received;
      _sent = _received = 0;
      final remaining = (await crypto('outbox'))['messages'] as List;
      return DeliveryProgress(
        sent,
        received,
        remaining.length,
        active: _pull != null || _sends.isNotEmpty,
        connected: _connected,
        weak: _weak,
      );
    } finally {
      _busy = false;
    }
  }

  void _rememberError(Object error, StackTrace stack) {
    if (_closed) return;
    _connected = false;
    _error ??= error;
    _errorStack ??= stack;
  }

  void _startSend(String key, Map<String, dynamic> message) {
    _sends[key] =
        () async {
          final elapsed = Stopwatch()..start();
          final ack = await transport.send(message);
          if (_closed) {
            return; // durable ciphertext remains retryable after reopen.
          }
          _connected = true;
          _weak = elapsed.elapsedMilliseconds > 2500;
          if (ack['durable'] != true) throw StateError('DURABLE_ACK_REQUIRED');
          await crypto('saved', {
            'group': message['group'],
            'id': message['id'],
            'seq': ack['serverSequence'],
          });
          _sent++;
        }().catchError(_rememberError).whenComplete(() {
          _sends.remove(key);
        });
  }

  Future<void> _pullMessages(String group) async {
    var cursor = (await crypto('cursor', {'group': group}))['cursor'] as String;
    for (var pages = 0; pages < 10 && !_closed; pages++) {
      Map<String, dynamic> page;
      try {
        final elapsed = Stopwatch()..start();
        page = await transport.sync(group, cursor);
        _connected = true;
        _weak = elapsed.elapsedMilliseconds > 2500;
      } on ApiFailure catch (failure) {
        if (failure.code == 'INVALID_CURSOR' && cursor.isNotEmpty) {
          cursor = '';
          continue;
        }
        rethrow;
      }
      if (_closed) return;
      final messages = page['messages'] as List;
      for (var i = 0; i < messages.length; i++) {
        if (_closed) return;
        final message = messages[i] as Map;
        final committed = await crypto('ingest', {
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
        if (committed['event'] case {'type': 'call_control', 'accepted': true}
            when !_closed) {
          onCallSignal?.call(group);
        }
        if (!_closed && isNewIncomingText(committed, message['envelopeKind'])) {
          onIncomingText?.call();
        }
      }
      final processed = page['peerProcessedSequence'];
      if (processed is int && processed > (_peerProcessed[group] ?? 0)) {
        await crypto('peer_processed', {'group': group, 'seq': processed});
        _peerProcessed[group] = processed;
      }
      _received += messages.length;
      cursor = page['nextCursor'] as String;
      if (page['hasMore'] != true) break;
    }
    if (_closed) return;
    final seq = (await crypto('cursor', {'group': group}))['seq'] as int;
    _scheduleReceipt(group, seq);
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
