import 'dart:convert';
import 'dart:io';

import 'account_credentials.dart';
import 'http_api.dart';
import 'src/rust/api.dart';
import 'transport.dart';

typedef DeviceLoginRequest = Future<dynamic> Function(
  String route, {
  Map<String, dynamic>? data,
  String? token,
  String? notFoundCode,
});

DeviceLoginRequest bindLoginRequest(HttpClient http, Uri endpoint) =>
    (route, {data, token, notFoundCode}) => meshHttp(
      http,
      endpoint,
      route,
      data: data,
      token: token,
      notFoundCode: notFoundCode,
    );

Future<Map<String, dynamic>> signedDeviceLogin({
  required Uri endpoint,
  required String username,
  required Map<String, dynamic> identity,
  required int version,
  required String password,
  required DeviceLoginRequest request,
  required Future<Map<String, dynamic>> Function(String payload) sign,
  CredentialDerivation derive = accountCredentialFields,
}) async {
  final device = identity['identity'] as String;
  final publicKey = identity['public_key'] as String;
  final challenge = await request(
    '/v1/auth/challenge',
    data: {'username': username, 'deviceId': device},
  ) as Map;
  _checkChallenge(challenge, device, username);
  final proof = await sign(challenge['payload'] as String);
  final fields = await derive(
    version: version,
    endpoint: endpoint,
    username: username,
    password: password,
  );
  return {
    'username': username,
    ...fields,
    'deviceId': device,
    'publicKey': publicKey,
    'clientOs': Platform.operatingSystem,
    'challengeId': challenge['challengeId'],
    'signature': proof['signature'],
  };
}

void _checkChallenge(Map challenge, String device, String username) {
  try {
    final payload = challenge['payload'] as String;
    if (payload.length > 2048) throw const FormatException();
    final parts = utf8.decode(base64Decode(payload)).split('\n');
    if (parts.length != 5 ||
        parts[0] != 'SecureMesh/device/v1' ||
        parts[1] != challenge['challengeId'] ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(parts[1]) ||
        parts[2] != device ||
        parts[3] != username ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(parts[4])) {
      throw const FormatException();
    }
  } catch (_) {
    throw ApiFailure(400, 'DEVICE_CHALLENGE_MISMATCH');
  }
}

/// Crash-safe setup of one local device. The SQLCipher journal precedes login;
/// retries sign with that same device, including an ambiguous/lost login reply.
class AccountSetup {
  AccountSetup({required this.store, required this.http});
  final NativeClient store;
  final HttpClient http;
  bool _busy = false;

  Future<Map<String, dynamic>> command(
    String op, [
    Map<String, dynamic> fields = const {},
  ]) async => jsonDecode(
    await store.execute(request: jsonEncode({'op': op, ...fields})),
  ) as Map<String, dynamic>;

  Future<void> prepare({
    required String device,
    required Uri endpoint,
    required String username,
    required bool registeredHere,
    int credentialVersion = 1,
  }) async {
    if (endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        (endpoint.path.isNotEmpty && endpoint.path != '/')) {
      throw ApiFailure(400, 'TLS_REQUIRED');
    }
    await command('init', {
      'identity': device,
      'onboarding': {
        'endpoint': endpoint.origin,
        'username': username,
        'registeredHere': registeredHere,
        'credentialVersion': credentialVersion,
      },
    });
  }

  Future<Map<String, dynamic>> state() => command('onboarding_state');

  Future<void> finish({String? password}) async {
    if (_busy) throw ApiFailure(409, 'ONBOARDING_BUSY');
    _busy = true;
    try {
      var current = await state();
      if (current['stage'] == 'complete') return;
      final draft = current['draft'] as Map<String, dynamic>?;
      if (draft == null) throw ApiFailure(400, 'ONBOARDING_DRAFT_MISSING');
      final endpoint = Uri.parse(draft['endpoint'] as String);
      if (current['stage'] == 'prepared') {
        if (password == null || password.isEmpty) {
          throw ApiFailure(401, 'ONBOARDING_PASSWORD_REQUIRED');
        }
        final me = await command('identity');
        final version = (draft['credentialVersion'] ?? 1) as int;
        final login = await signedDeviceLogin(
          endpoint: endpoint,
          username: draft['username'] as String,
          identity: me,
          version: version,
          password: password,
          request: bindLoginRequest(http, endpoint),
          sign: (payload) => command('sign', {'payload': payload}),
        );
        final attempt = await command('onboarding_attempt');
        Map<String, dynamic> session;
        try {
          session = await meshHttp(
            http,
            endpoint,
            '/v$version/auth/login',
            data: login,
          ) as Map<String, dynamic>;
        } on ApiFailure catch (failure) {
          if (attempt['priorUncertain'] == false &&
              const {400, 401, 403}.contains(failure.status)) {
            await command('onboarding_rejected');
          }
          rethrow;
        }
        await command('onboarding_session', {'session': session});
        current = await state();
      }
      final session = (current['draft'] as Map)['session'] as Map;
      Map<String, dynamic> account;
      try {
        account = await meshHttp(
          http,
          endpoint,
          '/v1/users/me',
          token: session['accessToken'] as String,
        ) as Map<String, dynamic>;
      } on ApiFailure catch (failure) {
        if (failure.status != 401) rethrow;
        await command('onboarding_reauthenticate');
        throw ApiFailure(401, 'ONBOARDING_SESSION_EXPIRED');
      }
      await command('onboarding_complete', {'account': account});
    } finally {
      _busy = false;
    }
  }
}
