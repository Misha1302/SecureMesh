import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:securemesh_client/session.dart';
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
    Map<String, dynamic> args = const {},
  ]) async =>
      jsonDecode(await store.execute(request: jsonEncode({'op': op, ...args})))
          as Map<String, dynamic>;
  var profile = await command('profile');
  final tls = SecurityContext(withTrustedRoots: true)
    ..setTrustedCertificates(input['cert'] as String);
  final http = HttpClient(context: tls);
  final session = AccountSession(
    http: http,
    endpoint: Uri.parse(profile['endpoint'] as String),
    profile: () => profile,
    persist: (updated) async {
      final next = {...profile, ...updated};
      await command('profile_put', {'profile': next});
      profile = next;
    },
  );
  try {
    final result = await session.request('/v1/users/me') as Map;
    if (result['deviceId'] != input['device'])
      throw StateError('DEVICE_CHANGED');
    stdout.writeln(jsonEncode({'ok': true}));
  } on ApiFailure catch (failure) {
    stdout.writeln(jsonEncode({'ok': false, 'code': failure.code}));
    exitCode = 2;
  } finally {
    session.close();
    http.close(force: true);
    store.dispose();
    RustLib.dispose();
  }
}
