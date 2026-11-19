import 'dart:io';

import 'http_api.dart';
import 'device_auth.dart';
import 'transport.dart';

/// Device-signed, crash-recoverable single-use rotation. No bearer fallback.
class AccountSession {
  AccountSession({
    required this.http,
    required this.endpoint,
    required this.profile,
    required this.prepareRefresh,
    required this.commitRefresh,
  });
  final HttpClient http;
  final Uri endpoint;
  final Map<String, dynamic> Function() profile;
  final Future<Map<String, dynamic>> Function() prepareRefresh;
  final Future<void> Function(Map<String, dynamic>) commitRefresh;
  Future<void>? _rotation;
  Future<void>? _signIn;
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
    int refreshAttempts = 0,
  }) async {
    _check();
    if (_signIn != null) await _signIn;
    _check();
    final token = profile()['accessToken'] as String;
    try {
      final response = await meshHttp(
        http,
        endpoint,
        route,
        data: data,
        method: method,
        token: token,
      );
      _check();
      return response;
    } on ApiFailure catch (failure) {
      _check();
      if (failure.status != 401 || refreshAttempts >= 2) rethrow;
      if (_signIn != null) {
        await _signIn;
      } else if (profile()['accessToken'] == token) {
        _rotation ??= (() async {
          final request = await prepareRefresh();
          _check();
          final updated = await meshHttp(
            http,
            endpoint,
            '/v1/auth/refresh/device',
            data: request,
          ) as Map<String, dynamic>;
          _check();
          if (updated['requestId'] != request['requestId'] ||
              updated['deviceId'] != request['deviceId'] ||
              updated['refreshBinding'] != 'device-signature-v1') {
            throw ApiFailure(502, 'REFRESH_RESPONSE_MISMATCH');
          }
          await commitRefresh(updated);
          _check();
        })().whenComplete(() => _rotation = null);
        await _rotation;
      }
      return request(
        route,
        data: data,
        method: method,
        refreshAttempts: refreshAttempts + 1,
      );
    }
  }

  /// Explicit password + same local signing key, never a new device identity.
  Future<void> reauthenticate({
    required String password,
    String? username,
    required DeviceCommand command,
    required Future<void> Function(Map<String, dynamic>, Map<String, dynamic>)
    commit,
  }) {
    _check();
    return _signIn ??= (() async {
      final rotating = _rotation;
      if (rotating != null) {
        try {
          await rotating;
        } catch (_) {
          // This explicit action repairs a failed refresh; it still proves the
          // account password and the existing device and cannot revive revoke.
          _check();
        }
      }
      _check();
      final oldUsername = profile()['username'] as String?;
      final selectedUsername = username ?? oldUsername;
      if (selectedUsername == null ||
          !RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(selectedUsername) ||
          (oldUsername != null && oldUsername != selectedUsername)) {
        throw ApiFailure(400, 'PROFILE_USERNAME_REQUIRED');
      }
      final proof = await deviceLoginProof(
        http: http,
        endpoint: endpoint,
        username: selectedUsername,
        command: command,
      );
      _check();
      final next = await meshHttp(
        http,
        endpoint,
        '/v1/auth/login',
        data: {
          'username': selectedUsername,
          'password': password,
          ...proof,
          'deviceBoundRefresh': true,
        },
      ) as Map<String, dynamic>;
      _check();
      if (next['deviceId'] != profile()['deviceId'] ||
          next['refreshBinding'] != 'device-signature-v1') {
        throw ApiFailure(502, 'SESSION_BINDING_MISMATCH');
      }
      final account = await meshHttp(
        http,
        endpoint,
        '/v1/users/me',
        token: next['accessToken'] as String,
      ) as Map<String, dynamic>;
      _check();
      if ((profile()['userId'] != null &&
              account['userId'] != profile()['userId']) ||
          account['deviceId'] != profile()['deviceId']) {
        throw ApiFailure(502, 'SESSION_BINDING_MISMATCH');
      }
      await commit(next, {...account, 'username': selectedUsername});
      _check();
    })().whenComplete(() => _signIn = null);
  }
}
