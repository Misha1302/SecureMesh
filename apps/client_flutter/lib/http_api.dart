import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'transport.dart';

/// Shared bounded HTTPS path for onboarding and authenticated fallback.
Future<dynamic> meshHttp(
  HttpClient http,
  Uri endpoint,
  String route, {
  Map<String, dynamic>? data,
  String? method,
  String? token,
}) async {
  final uri = endpoint.resolve(route);
  if (uri.scheme != 'https' ||
      uri.origin != endpoint.origin ||
      uri.userInfo.isNotEmpty) {
    throw ApiFailure(400, 'TLS_REQUIRED');
  }
  final request = await http.openUrl(
    method ?? (data == null ? 'GET' : 'POST'),
    uri,
  );
  request.followRedirects = false;
  request.headers.contentType = ContentType.json;
  if (token != null) {
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  }
  if (data != null) request.write(jsonEncode(data));
  try {
    final response = await request.close().timeout(const Duration(seconds: 20));
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 20))) {
      if (bytes.length + chunk.length > 262144) {
        throw ApiFailure(502, 'RESPONSE_TOO_LARGE');
      }
      bytes.addAll(chunk);
    }
    dynamic body;
    if (bytes.isNotEmpty) body = jsonDecode(utf8.decode(bytes));
    if (response.statusCode >= 300) {
      throw ApiFailure(
        response.statusCode,
        body is Map && body['code'] is String
            ? body['code'] as String
            : 'HTTP_REJECTED',
      );
    }
    return body;
  } catch (_) {
    request.abort();
    rethrow;
  }
}
