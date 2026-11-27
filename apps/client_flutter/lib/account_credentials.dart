import 'dart:convert';

import 'src/rust/api.dart' as native;

typedef CredentialDerivation = Future<Map<String, String>> Function({
  required int version,
  required Uri endpoint,
  required String username,
  required String password,
});

Future<Map<String, String>> accountCredentialFields({
  required int version,
  required Uri endpoint,
  required String username,
  required String password,
}) async {
  if (version == 1) return {'password': password};
  if (version != 2) throw StateError('Unsupported credential version');
  final response = jsonDecode(
    await native.command(
      path: '',
      request: jsonEncode({
        'op': 'derive_server_credential_v2',
        'endpoint': endpoint.origin,
        'username': username,
        'password': password,
      }),
    ),
  ) as Map;
  return {'credential': response['credential'] as String};
}
