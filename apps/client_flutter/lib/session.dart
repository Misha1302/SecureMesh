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
  Future<void>? _replacement;
  bool _closed = false;
  void close() {
    _closed = true;
  }

  void _check() {
    if (_closed) throw ApiFailure(499, 'SESSION_CLOSED');
  }

  Future<void> replaceTokens(Map<String, dynamic> verifiedTokens) {
    _check();
    if (_replacement != null) throw ApiFailure(409, 'SESSION_REPLACING');
    final previousRotation = _rotation;
    final replacing = () async {
      // A rotation that had already started may be writing old tokens.
      // Let it settle before committing the verified replacement.
      try {
        await previousRotation;
      } catch (_) {}
      _check();
      await persist(verifiedTokens);
      _check();
    }();
    return _replacement = replacing.whenComplete(() => _replacement = null);
  }

  Future<dynamic> request(
    String route, {
    Map<String, dynamic>? data,
    String? method,
    String? notFoundCode,
    bool retried = false,
  }) => authorized(
    (token) => meshHttp(
      http,
      endpoint,
      route,
      data: data,
      method: method,
      token: token,
      notFoundCode: notFoundCode,
    ),
    retried: retried,
  );

  Future<T> authorized<T>(
    Future<T> Function(String token) action, {
    bool retried = false,
  }) async {
    _check();
    final replacing = _replacement;
    if (replacing != null) {
      await replacing;
      _check();
    }
    final token = profile()['accessToken'] as String;
    try {
      final response = await action(token);
      _check();
      return response;
    } on ApiFailure catch (failure) {
      _check();
      if (failure.status != 401 || retried) rethrow;
      final replacing = _replacement;
      if (replacing != null) {
        await replacing;
        _check();
      }
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
