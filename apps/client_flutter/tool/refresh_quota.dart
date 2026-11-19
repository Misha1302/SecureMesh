import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:securemesh_client/http_api.dart';
import 'package:securemesh_client/src/rust/api.dart';
import 'package:securemesh_client/src/rust/frb_generated.dart';
import 'package:securemesh_client/transport.dart';

Future<void> main(List<String> args) async {
  final input = jsonDecode(File(args.single).readAsStringSync()) as Map;
  await RustLib.init(
    externalLibrary: ExternalLibrary.open(input['library'] as String),
  );
  final store = await NativeClient.open(
    path: input['path'] as String,
    passphrase: input['passphrase'] as String,
  );
  Future<Map<String, dynamic>> command(
    String op, [
    Map<String, dynamic> fields = const {},
  ]) async => jsonDecode(
    await store.execute(request: jsonEncode({'op': op, ...fields})),
  ) as Map<String, dynamic>;
  final tls = SecurityContext(withTrustedRoots: true)
    ..setTrustedCertificates(input['cert'] as String);
  final http = HttpClient(context: tls);
  final endpoint = Uri.parse(input['endpoint'] as String);
  final clock = Stopwatch()..start();
  var accepted = 0, throttles = 0;
  try {
    while (accepted < (input['count'] as int)) {
      if (clock.elapsed > const Duration(seconds: 240)) {
        throw StateError('QUOTA_WATCHDOG');
      }
      final request =
          (await command('refresh_prepare', {
                'endpoint': endpoint.origin,
              }))['request']
              as Map<String, dynamic>;
      try {
        final response = await meshHttp(
          http,
          endpoint,
          '/v1/auth/refresh/device',
          data: request,
        ) as Map<String, dynamic>;
        await command('refresh_complete', {'response': response});
        accepted++;
      } on ApiFailure catch (error) {
        if (error.status == 429 && error.code == 'REFRESH_LIMIT') {
          stdout.writeln(
            jsonEncode({
              'accepted': accepted,
              'limited': true,
              'throttles': throttles,
            }),
          );
          return;
        }
        if (error.status != 429) rethrow;
        throttles++;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    stdout.writeln(
      jsonEncode({
        'accepted': accepted,
        'limited': false,
        'throttles': throttles,
      }),
    );
  } finally {
    http.close(force: true);
    store.dispose();
    RustLib.dispose();
  }
}
