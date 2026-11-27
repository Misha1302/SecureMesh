import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'local_client.dart';
import 'session.dart';
import 'transport.dart';

const attachmentLimit = 4 * 1024 * 1024;
const _tagLength = 16;
const _timeout = Duration(seconds: 45);

class AttachmentDeferredForMessages implements Exception {}

abstract interface class BlobTransport {
  Future<void> put(String id, Uint8List bytes, void Function(double) progress);
  Future<Uint8List> get(
    String message,
    String id,
    int size,
    void Function(double) progress,
  );
  void close();
}

class SessionBlobs implements BlobTransport {
  SessionBlobs(this.session, this.group, this.crypto)
    : client = nativeHttpClient();
  final AccountSession session;
  final String group;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
  crypto;
  final HttpClient client;
  bool closed = false;
  static const block = 32768;

  Future<void> _yieldToMessages() async {
    final state = await crypto('outbox_pending', {});
    if (state['pending'] == true) throw AttachmentDeferredForMessages();
  }

  Uri _uri(String id, {bool parts = false, int? offset}) {
    final endpoint = session.endpoint;
    final uri = endpoint.replace(
      pathSegments: [
        'v1',
        'conversations',
        group,
        'blobs',
        id,
        if (parts) 'parts',
      ],
      queryParameters: offset == null ? {} : {'offset': offset.toString()},
      fragment: '',
    );
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.origin != endpoint.origin) {
      throw StateError('HTTPS required');
    }
    return uri;
  }

  void _active() {
    if (closed) throw StateError('Closed attachment session');
  }

  Future<({int status, Uint8List bytes, String? range})> _request(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Uint8List? body,
    required int limit,
  }) async {
    for (var attempt = 0; ; attempt++) {
      _active();
      final response = await _once(
        method,
        uri,
        headers: headers,
        body: body,
        limit: limit,
      );
      if (response.status != 429 || attempt == 3) return response;
      // The API replenishes its shared per-address token bucket every ten seconds.
      // Retrying the same chunk is safe even when another client has advanced it.
      await Future<void>.delayed(const Duration(seconds: 10));
    }
  }

  Future<({int status, Uint8List bytes, String? range})> _once(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Uint8List? body,
    required int limit,
  }) => session.authorized((token) async {
    _active();
    final request = await client.openUrl(method, uri).timeout(_timeout);
    try {
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      headers.forEach(request.headers.set);
      if (body != null) {
        request.headers.contentType = ContentType.binary;
        request.contentLength = body.length;
        request.add(body);
      }
      final response = await request.close().timeout(_timeout);
      if (response.statusCode == 401) throw ApiFailure(401, 'SESSION_EXPIRED');
      final bytes = BytesBuilder(copy: false);
      await for (final part in response.timeout(_timeout)) {
        if (part.length + bytes.length > limit) {
          throw const FormatException('SIZE');
        }
        bytes.add(part);
      }
      _active();
      return (
        status: response.statusCode,
        bytes: bytes.takeBytes(),
        range: response.headers.value(HttpHeaders.contentRangeHeader),
      );
    } catch (_) {
      request.abort();
      rethrow;
    }
  });

  @override
  Future<void> put(
    String id,
    Uint8List bytes,
    void Function(double) progress,
  ) async {
    final size = bytes.length;
    if (size <= _tagLength || size > attachmentLimit + _tagLength) {
      throw const FormatException('SIZE');
    }
    final digest = sha256.convert(bytes).toString();
    int checkedOffset(Uint8List ack) {
      final data = jsonDecode(utf8.decode(ack)) as Map<String, dynamic>;
      final offset = data['offset'] as int;
      if (data['digest'] != digest ||
          offset < 0 ||
          offset > size ||
          data['complete'] != (offset == size) ||
          (offset != size && offset % block != 0)) {
        throw const FormatException('INVALID_UPLOAD_STATE');
      }
      return offset;
    }

    final status = await _request('GET', _uri(id, parts: true), limit: 4096);
    if (status.status != 200 && status.status != 404) {
      throw ApiFailure(status.status, 'BLOB_UPLOAD_FAILED');
    }
    var offset = status.status == 404 ? 0 : checkedOffset(status.bytes);
    progress(offset / size);
    while (offset < size) {
      await _yieldToMessages();
      final end = math.min(offset + block, size);
      final response = await _request(
        'PUT',
        _uri(id, parts: true, offset: offset),
        headers: {'X-Blob-Length': '$size', 'X-Blob-SHA256': digest},
        body: Uint8List.sublistView(bytes, offset, end),
        limit: 4096,
      );
      if (response.status != 200) {
        throw ApiFailure(response.status, 'BLOB_UPLOAD_FAILED');
      }
      offset = checkedOffset(response.bytes);
      if (offset < end) throw const FormatException('INVALID_UPLOAD_OFFSET');
      progress(offset / size);
    }
  }

  @override
  Future<Uint8List> get(
    String message,
    String id,
    int size,
    void Function(double) progress,
  ) async {
    if (size <= _tagLength || size > attachmentLimit + _tagLength) {
      throw const FormatException('SIZE');
    }
    final args = {'group': group, 'id': message};
    _active();
    final previous = await crypto('attachment_download_prefix', args);
    final prefix = base64Decode(previous['ciphertext'] as String);
    if (prefix.length > size ||
        (prefix.length != size && prefix.length % block != 0)) {
      throw const FormatException('INVALID_DOWNLOAD_OFFSET');
    }
    final result = BytesBuilder(copy: false)..add(prefix);
    progress(result.length / size);
    while (result.length < size) {
      await _yieldToMessages();
      final offset = result.length;
      final end = math.min(size, offset + block);
      final response = await _request(
        'GET',
        _uri(id),
        headers: {HttpHeaders.rangeHeader: 'bytes=$offset-${end - 1}'},
        limit: block,
      );
      if (response.status != 206) {
        throw ApiFailure(response.status, 'BLOB_DOWNLOAD_FAILED');
      }
      if (response.range != 'bytes $offset-${end - 1}/$size' ||
          response.bytes.length != end - offset) {
        throw const FormatException('INVALID_DOWNLOAD_RANGE');
      }
      _active();
      await crypto('attachment_download_part', {
        ...args,
        'offset': offset,
        'ciphertext': base64Encode(response.bytes),
      });
      result.add(response.bytes);
      progress(result.length / size);
    }
    return result.takeBytes();
  }

  @override
  void close() {
    closed = true;
    client.close(force: true);
  }
}
