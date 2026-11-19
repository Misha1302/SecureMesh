import 'dart:convert';
import 'dart:io';

import 'http_api.dart';
import 'device_auth.dart';
import 'src/rust/api.dart';
import 'transport.dart';

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
        final proof = await deviceLoginProof(
          http: http,
          endpoint: endpoint,
          username: draft['username'] as String,
          command: command,
        );
        final attempt = await command('onboarding_attempt');
        Map<String, dynamic> session;
        try {
          session = await meshHttp(
            http,
            endpoint,
            '/v1/auth/login',
            data: {
              'username': draft['username'],
              'password': password,
              ...proof,
              'deviceBoundRefresh': true,
            },
          ) as Map<String, dynamic>;
        } on ApiFailure catch (failure) {
          if (attempt['priorUncertain'] == false &&
              const {400, 401, 403}.contains(failure.status)) {
            await command('onboarding_rejected');
          }
          rethrow;
        }
        if (session['refreshBinding'] != 'device-signature-v1') {
          throw ApiFailure(502, 'REFRESH_BINDING_REQUIRED');
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
