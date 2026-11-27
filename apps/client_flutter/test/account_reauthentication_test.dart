import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:securemesh_client/account_reauthentication.dart';
import 'package:securemesh_client/session.dart';
import 'package:securemesh_client/transport.dart';

const _device = 'be579f89-7042-4cc4-9344-04ae809fd9f2';
const _user = '682fc813-dccf-4da2-892a-05f2b5db384a';
const _challenge = 'd86f929c-f5d9-43ab-9027-add940e0ca5b';
const _trust = 'DEVICE_TRUSTED';
const _password = 'test account password';
const _origin = 'https://chat.example.test';

class _Fixture {
  final profile = <String, dynamic>{
    'endpoint': _origin,
    'username': 'tester',
    'userId': _user,
    'deviceId': _device,
    'trustState': _trust,
    'credentialVersion': 2,
    'accessToken': 'old-access',
    'refreshToken': 'old-refresh',
  };
  final calls = <String>[];
  String challengeDevice = _device;
  int? errorStatus;
  int signatures = 0;
  Map<String, dynamic> account = {
    'userId': _user,
    'deviceId': _device,
    'trustState': _trust,
  };
  final returnedSession = <String, dynamic>{
    'deviceId': _device,
    'trustState': _trust,
    'accessToken': 'new-access',
    'refreshToken': 'new-refresh',
    'expiresIn': 900,
    'unexpected': 'ignored',
  };

  Future<Map<String, dynamic>> run() => reauthenticateDevice(
    profile: profile,
    endpoint: Uri.parse(_origin),
    identity: {'identity': _device, 'public_key': 'original-public'},
    password: _password,
    request: (route, {data, token, notFoundCode}) async {
      calls.add(route);
      switch (route) {
        case '/v1/auth/challenge':
          expect(data, {'username': 'tester', 'deviceId': _device});
          return {
            'challengeId': _challenge,
            'payload': base64Encode(
              utf8.encode(
                'SecureMesh/device/v1\n$_challenge\n$challengeDevice\ntester\n${'a' * 64}',
              ),
            ),
          };
        case '/v1/auth/reauthenticate':
        case '/v2/auth/reauthenticate':
          final body = data!;
          expect(body['expectedUserId'], _user);
          expect(body['expectedTrustState'], _trust);
          expect(body['deviceId'], _device);
          expect(body['publicKey'], 'original-public');
          expect(body['signature'], 'proof');
          expect(body['challengeId'], _challenge);
          if (route.startsWith('/v2/')) {
            expect(body['credential'], 'derived');
            expect(body.containsKey('password'), isFalse);
            expect(jsonEncode(body), isNot(contains(_password)));
          } else {
            expect(body['password'], _password);
            expect(body.containsKey('credential'), isFalse);
          }
          if (errorStatus case final int status) {
            throw ApiFailure(status, notFoundCode!);
          }
          return returnedSession;
        case '/v1/users/me':
          expect(token, 'new-access');
          return account;
        default:
          fail('Unexpected login route $route');
      }
    },
    sign: (payload) async {
      signatures++;
      expect(utf8.decode(base64Decode(payload)), contains(_device));
      return {'signature': 'proof'};
    },
    derive:
        ({
          required version,
          required endpoint,
          required username,
          required password,
        }) async {
          expect(version, profile['credentialVersion']);
          expect(endpoint.origin, _origin);
          expect(username, 'tester');
          expect(password, _password);
          return version == 2
              ? {'credential': 'derived'}
              : {'password': password};
        },
  );
}

void main() {
  test(
    'replacement tokens remain unavailable until durable persistence',
    () async {
      final persistGate = Completer<void>();
      final existing = {'accessToken': 'old', 'profileField': 'retain'};
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final owner = AccountSession(
        http: http,
        endpoint: Uri.parse(_origin),
        profile: () => existing,
        persist: (tokens) async {
          await persistGate.future;
          existing['accessToken'] = tokens['accessToken'] as String;
        },
      );
      final tokens = owner.replaceTokens({'accessToken': 'verified'});
      var sent = false;
      final request = owner.authorized((token) async {
        sent = true;
        return token;
      });
      await Future<void>.delayed(Duration.zero);
      expect(sent, isFalse);
      expect(existing['accessToken'], 'old');
      persistGate.complete();
      await tokens;
      expect(await request, 'verified');
      expect(existing['profileField'], 'retain');
    },
  );

  test(
    'v2 verifies the same account before returning only replacement tokens',
    () async {
      final fixture = _Fixture();
      expect(await fixture.run(), {
        'accessToken': 'new-access',
        'refreshToken': 'new-refresh',
        'expiresIn': 900,
      });
      expect(fixture.calls, [
        '/v1/auth/challenge',
        '/v2/auth/reauthenticate',
        '/v1/users/me',
      ]);
      expect(fixture.profile['accessToken'], 'old-access');
    },
  );

  test('only explicit v1 profiles use the v1 endpoint', () async {
    final legacy = _Fixture()..profile['credentialVersion'] = 1;
    expect((await legacy.run())['accessToken'], 'new-access');
    expect(legacy.calls[1], '/v1/auth/reauthenticate');
    final unspecified = _Fixture()..profile.remove('credentialVersion');
    await expectLater(unspecified.run(), throwsA(isA<ApiFailure>()));
    expect(unspecified.calls, isEmpty);
  });

  test(
    'mismatched challenge, account, device or trust discards the session',
    () async {
      final wrongChallenge = _Fixture()..challengeDevice = _user;
      await expectLater(wrongChallenge.run(), throwsA(isA<ApiFailure>()));
      expect(wrongChallenge.signatures, 0);
      final wrongDevice = _Fixture()..returnedSession['deviceId'] = _user;
      await expectLater(wrongDevice.run(), throwsA(isA<ApiFailure>()));
      expect(wrongDevice.calls, hasLength(2));
      for (final (field, value) in [
        ('userId', _device),
        ('deviceId', _user),
        ('trustState', 'DEVICE_PENDING_TRUST'),
      ]) {
        final wrongAccount = _Fixture()..account[field] = value;
        await expectLater(wrongAccount.run(), throwsA(isA<ApiFailure>()));
        expect(wrongAccount.profile['accessToken'], 'old-access');
      }
    },
  );

  test('v2 404 does not fall back to any legacy route', () async {
    final fixture = _Fixture()..errorStatus = 404;
    await expectLater(
      fixture.run(),
      throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 404)),
    );
    expect(fixture.calls, ['/v1/auth/challenge', '/v2/auth/reauthenticate']);
  });
}
