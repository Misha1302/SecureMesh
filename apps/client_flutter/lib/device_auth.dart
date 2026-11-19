import 'dart:convert';
import 'dart:io';

import 'http_api.dart';
import 'transport.dart';

typedef DeviceCommand = Future<Map<String, dynamic>> Function(
  String operation,
  Map<String, dynamic> fields,
);

/// Sign only the device-authentication transcript for this account/device.
/// Shared by initial setup and explicit same-key reauthentication.
Future<Map<String, dynamic>> deviceLoginProof({
  required HttpClient http,
  required Uri endpoint,
  required String username,
  required DeviceCommand command,
}) async {
  final me = await command('identity', {});
  final challenge = await meshHttp(
    http,
    endpoint,
    '/v1/auth/challenge',
    data: {'username': username, 'deviceId': me['identity']},
  ) as Map;
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
        parts[2] != me['identity'] ||
        parts[3] != username ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(parts[4])) {
      throw const FormatException();
    }
  } catch (_) {
    throw ApiFailure(400, 'DEVICE_CHALLENGE_MISMATCH');
  }
  final proof = await command('sign', {'payload': challenge['payload']});
  return {
    'deviceId': me['identity'],
    'publicKey': me['public_key'],
    'challengeId': challenge['challengeId'],
    'signature': proof['signature'],
  };
}
