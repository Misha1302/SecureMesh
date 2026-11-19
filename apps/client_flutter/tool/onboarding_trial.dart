import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:securemesh_client/account_setup.dart';
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
  final tls = SecurityContext(withTrustedRoots: true)
    ..setTrustedCertificates(input['cert'] as String);
  final http = HttpClient(context: tls);
  final setup = AccountSetup(store: store, http: http);
  try {
    if (input['create'] == true) {
      await setup.prepare(
        device: input['device'] as String,
        endpoint: Uri.parse(input['endpoint'] as String),
        username: input['username'] as String,
        registeredHere: input['registeredHere'] == true,
      );
    }
    await setup.finish(password: input['accountPassword'] as String?);
    final state = await setup.state();
    if (state['stage'] != 'complete' || state.containsKey('draft')) {
      throw StateError('PROFILE_NOT_ATOMICALLY_COMPLETED');
    }
    stdout.writeln(jsonEncode({'stage': 'complete'}));
    if (input['waitAfterComplete'] == true) stdin.readLineSync();
  } on ApiFailure catch (failure) {
    stdout.writeln(jsonEncode({'stage': 'rejected', 'code': failure.code}));
    exitCode = 2;
  } finally {
    http.close(force: true);
    store.dispose();
    RustLib.dispose();
  }
}
