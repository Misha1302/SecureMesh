import 'dart:io';

import 'http_api.dart';
import 'transport.dart';

/// Refresh tokens are single-use. Concurrent HTTP/WSS fallback and settings
/// requests share one rotation, persisted before the new session is used.
class AccountSession {
  AccountSession({
    required this.http,
    required this.endpoint,
    required this.profile,
    required this.persist,
  });
  final HttpClient http;
  final Uri endpoint;
  final Map<String, dynamic> Function() profile;
  final Future<void> Function(Map<String, dynamic>) persist;
  Future<void>? _rotation;
  bool _closed = false;
  void close() {
    _closed = true;
  }

  void _check() {
    if (_closed) throw ApiFailure(499, 'SESSION_CLOSED');
  }

  Future<dynamic> request(
    String route, {
    Map<String, dynamic>? data,
    String? method,
    bool retried = false,
  }) => authorized(
    (token) => meshHttp(
      http,
      endpoint,
      route,
      data: data,
      method: method,
      token: token,
    ),
    retried: retried,
  );

  Future<T> authorized<T>(
    Future<T> Function(String token) action, {
    bool retried = false,
  }) async {
    _check();
    final token = profile()['accessToken'] as String;
    try {
      final response = await action(token);
      _check();
      return response;
    } on ApiFailure catch (failure) {
      _check();
      if (failure.status != 401 || retried) rethrow;
      if (profile()['accessToken'] == token) {
        _rotation ??= (() async {
          final updated = await meshHttp(
            http,
            endpoint,
            '/v1/auth/refresh',
            data: {'token': profile()['refreshToken']},
          ) as Map<String, dynamic>;
          _check();
          await persist(updated);
          _check();
        })().whenComplete(() => _rotation = null);
        await _rotation;
      }
      return authorized(action, retried: true);
    }
  }
}
