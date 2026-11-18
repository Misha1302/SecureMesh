import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';

import 'src/wire/wire.pb.dart' as wire;

class ApiFailure implements Exception {
  final int status;
  final String code;
  ApiFailure(this.status, [this.code = '']);
}

typedef HttpsRequest = Future<dynamic> Function(
  String route, {
  Map<String, dynamic>? data,
});

/// A bounded window permits text and sync to share a high-RTT connection.
/// Durable outbox and cursor ownership stay with
/// the encrypted store; changing transport never creates another message ID.
class MeshTransport {
  MeshTransport({
    required this.endpoint,
    required this.device,
    required this.token,
    required this.http,
    required this.https,
    this.timeout = const Duration(seconds: 15),
    this.probeDelay = const Duration(seconds: 30),
  }) {
    if (endpoint.scheme != 'https' || endpoint.userInfo.isNotEmpty) {
      throw ArgumentError('TLS_REQUIRED');
    }
  }

  final Uri endpoint;
  final String device;
  final String Function() token;
  final HttpClient http;
  final HttpsRequest https;
  final Duration timeout, probeDelay;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  final Map<String, Completer<wire.Frame>> _pending = {};
  Future<void>? _connecting;
  DateTime _probeAfter = DateTime.fromMillisecondsSinceEpoch(0);
  bool _closed = false;
  int _operations = 0;
  String mode = 'disconnected';
  int sentApplicationBytes=0,receivedApplicationBytes=0;
  static const maxFrame = 131072;
  static const maxInFlight = 6;

  void close() {
    _closed = true;
    _disconnect();
  }

  void _disconnect() {
    final socket = _socket;
    _socket = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    if (socket != null) unawaited(socket.close().catchError((_) {}));
    final pending = _pending.values.toList();
    _pending.clear();
    for (final request in pending) {
      if (!request.isCompleted) {
        request.completeError(const SocketException('STREAM_DISCONNECTED'));
      }
    }
    if (_closed) mode = 'closed';
  }

  void _receive(dynamic data) {
    try {
      if (data is! List<int> || data.length > maxFrame + 5) {
        throw const FormatException('INVALID_STREAM_FRAME');
      }
      receivedApplicationBytes+=data.length;
      var length = 0, offset = 0, shift = 0;
      while (true) {
        if (offset >= data.length || offset >= 5) {
          throw const FormatException('INVALID_FRAME_LENGTH');
        }
        final byte = data[offset++];
        length |= (byte & 127) << shift;
        if (byte < 128) break;
        shift += 7;
      }
      if (length < 1 || length > maxFrame || length != data.length - offset) {
        throw const FormatException('INVALID_FRAME_LENGTH');
      }
      final response = wire.Frame.fromBuffer(data.sublist(offset));
      final key = base64Encode(response.requestId);
      final pending = _pending[key];
      if (response.protocolVersion != 1 || pending == null) {
        throw const FormatException('STREAM_CORRELATION_FAILED');
      }
      _pending.remove(key);
      pending.complete(response);
    } catch (_) {
      final pending = _pending.values.toList();
      _pending.clear();
      for (final request in pending) {
        if (!request.isCompleted) {
          request.completeError(ApiFailure(502, 'INVALID_STREAM_FRAME'));
        }
      }
      _disconnect();
    }
  }

  Future<wire.Frame> _exchange(wire.Frame frame) async {
    if (_closed) throw const SocketException('TRANSPORT_CLOSED');
    if (_pending.length >= maxInFlight) throw StateError('STREAM_BACKPRESSURE');
    final random = Random.secure();
    frame
      ..protocolVersion = 1
      ..requestId = List.generate(16, (_) => random.nextInt(256));
    final bytes = frame.writeToBuffer();
    if (bytes.length > maxFrame) throw ApiFailure(413, 'FRAME_TOO_LARGE');
    final prefix = <int>[];
    var remaining = bytes.length;
    while (remaining > 127) {
      prefix.add((remaining & 127) | 128);
      remaining >>= 7;
    }
    prefix.add(remaining);
    final pending = Completer<wire.Frame>();
    final key = base64Encode(frame.requestId);
    _pending[key] = pending;
    // Install the timeout/error listener before sending on a possibly dead socket.
    final future = pending.future.timeout(timeout);
    try {
      sentApplicationBytes+=prefix.length+bytes.length;
      _socket!.add(Uint8List.fromList([...prefix, ...bytes]));
    } catch (_) {
      _disconnect();
    }
    wire.Frame response;
    try {
      response = await future;
    } finally {
      _pending.remove(key);
    }
    if (response.kind == wire.FrameKind.SERVER_ERROR) {
      throw ApiFailure(
        response.serverError.code,
        response.serverError.stableCode,
      );
    }
    return response;
  }

  Future<void> _connect() async {
    if (_connecting != null) return _connecting;
    if (_socket != null) return;
    _connecting = _openConnection().whenComplete(() => _connecting = null);
    return _connecting;
  }

  Future<void> _openConnection() async {
    final uri = endpoint.resolve('/v1/stream').replace(scheme: 'wss');
    var abandoned = false;
    final connecting =
        WebSocket.connect(
          uri.toString(),
          headers: {HttpHeaders.authorizationHeader: 'Bearer ${token()}'},
          customClient: http,
          compression: CompressionOptions.compressionOff,
        ).then((socket) {
          if (abandoned || _closed) unawaited(socket.close());
          return socket;
        });
    final socket = await connecting.timeout(
      timeout,
      onTimeout: () {
        abandoned = true;
        throw TimeoutException('STREAM_CONNECT_TIMEOUT');
      },
    );
    if (_closed) {
      unawaited(socket.close());
      throw const SocketException('TRANSPORT_CLOSED');
    }
    _socket = socket;
    _subscription = socket.listen(
      (data) {
        if (identical(socket, _socket)) _receive(data);
      },
      onError: (_) {
        if (identical(socket, _socket)) _disconnect();
      },
      onDone: () {
        if (identical(socket, _socket)) _disconnect();
      },
      cancelOnError: true,
    );
    final hello = await _exchange(
      wire.Frame(
        kind: wire.FrameKind.HELLO,
        hello: wire.Hello(
          supportedVersions: [1],
          clientDeviceId: uuidBytes(device),
        ),
      ),
    );
    if (hello.kind != wire.FrameKind.HELLO ||
        !hello.hello.supportedVersions.contains(1)) {
      throw ApiFailure(502, 'INVALID_HELLO');
    }
    mode = 'wss';
  }

  Future<dynamic> _perform(
    wire.Frame frame,
    dynamic Function(wire.Frame) decode,
    String route, {
    Map<String, dynamic>? data,
  }) async {
    if (_closed) throw const SocketException('TRANSPORT_CLOSED');
    if (_operations >= maxInFlight) throw StateError('TRANSPORT_BACKPRESSURE');
    _operations++;
    try {
      if (!DateTime.now().isBefore(_probeAfter)) {
        try {
          await _connect();
          return decode(await _exchange(frame));
        } on ApiFailure catch (failure) {
          // Refresh remains HTTPS-only. Do not retry a rejected epoch/ID/key over
          // another transport as if it were an ambiguous network failure.
          if (failure.status != 401) {
            if (failure.status == 502) _disconnect();
            rethrow;
          }
          _disconnect();
        } on TimeoutException {
          _disconnect();
        } on IOException {
          _disconnect();
        }
        _probeAfter = DateTime.now().add(probeDelay);
      }
      if (_closed) throw const SocketException('TRANSPORT_CLOSED');
      mode = 'https';
      return await https(route, data: data);
    } finally {
      _operations--;
    }
  }

  Future<Map<String, dynamic>> send(Map<String, dynamic> message) async {
    final result = await _perform(
      wire.Frame(
        kind: wire.FrameKind.SEND_ENCRYPTED,
        encrypted: wire.EncryptedEnvelope(
          conversationId: uuidBytes(message['group'] as String),
          clientMessageId: uuidBytes(message['id'] as String),
          mlsEpoch: Int64(message['epoch'] as int),
          envelopeKind: wire.EnvelopeKind.valueOf(message['kind'] as int),
          opaqueCiphertext: base64Decode(message['ciphertext'] as String),
        ),
      ),
      (response) {
        final ack = response.durableAck;
        if (response.kind != wire.FrameKind.DURABLE_ACK ||
            uuidString(ack.conversationId) != message['group'] ||
            uuidString(ack.clientMessageId) != message['id'] ||
            ack.serverSequence <= Int64.ZERO) {
          throw ApiFailure(502, 'INVALID_DURABLE_ACK');
        }
        return {
          'durable': true,
          'serverSequence': ack.serverSequence.toInt(),
          'serverMessageId': uuidString(ack.serverMessageId),
          'alreadyCommitted': ack.alreadyCommitted,
        };
      },
      '/v1/messages',
      data: {
        'conversationId': message['group'],
        'clientMessageId': message['id'],
        'mlsEpoch': message['epoch'],
        'envelopeKind': message['kind'],
        'ciphertext': message['ciphertext'],
      },
    );
    return result as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> sync(
    String group,
    String cursor, {
    int limit = 6,
  }) async {
    final query = Uri(
      queryParameters: {
        'conversationId': group,
        'cursor': cursor,
        'limit': '$limit',
      },
    ).query;
    final result = await _perform(
      wire.Frame(
        kind: wire.FrameKind.SYNC_REQUEST,
        syncRequest: wire.SyncRequest(
          conversationId: uuidBytes(group),
          opaqueCursor: utf8.encode(cursor),
          limit: limit,
        ),
      ),
      (response) {
        final page = response.syncResponse;
        if (response.kind != wire.FrameKind.SYNC_RESPONSE ||
            uuidString(page.conversationId) != group ||
            page.messages.length > limit) {
          throw ApiFailure(502, 'INVALID_SYNC_RESPONSE');
        }
        return {
          'conversationId': group,
          'nextCursor': utf8.decode(page.nextCursor),
          'hasMore': page.hasMore,
          'messages': page.messages
              .map(
                (m) => {
                  'clientMessageId': uuidString(m.clientMessageId),
                  'senderDeviceId': uuidString(m.senderDeviceId),
                  'serverMessageId': uuidString(m.serverMessageId),
                  'serverSequence': m.serverSequence.toInt(),
                  'mlsEpoch': m.mlsEpoch.toInt(),
                  'envelopeKind': m.envelopeKind.value,
                  'ciphertext': base64Encode(m.opaqueCiphertext),
                  'ciphertextSha256': base64Encode(m.ciphertextSha256),
                },
              )
              .toList(),
        };
      },
      '/v1/sync?$query',
    );
    return result as Map<String, dynamic>;
  }

  Future<void> ack(String group, int sequence) async {
    await _perform(
      wire.Frame(
        kind: wire.FrameKind.PROCESSED_ACK,
        processedAck: wire.ProcessedAck(
          conversationId: uuidBytes(group),
          highestContiguousPersistedSequence: Int64(sequence),
        ),
      ),
      (response) {
        if (response.kind != wire.FrameKind.PROCESSED_ACK ||
            uuidString(response.processedAck.conversationId) != group ||
            response.processedAck.highestContiguousPersistedSequence.toInt() !=
                sequence) {
          throw ApiFailure(502, 'INVALID_PROCESSED_ACK');
        }
        return null;
      },
      '/v1/acks',
      data: {'conversationId': group, 'sequence': sequence},
    );
  }
}

List<int> uuidBytes(String value) {
  if (!RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
      .hasMatch(value)) {
    throw const FormatException('INVALID_UUID');
  }
  final hex = value.replaceAll('-', '');
  return List.generate(
    16,
    (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
  );
}

String uuidString(List<int> bytes) {
  if (bytes.length != 16) throw const FormatException('INVALID_UUID');
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
