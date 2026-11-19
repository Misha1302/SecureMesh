import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:securemesh_client/session.dart';
import 'package:securemesh_client/src/rust/api.dart';
import 'package:securemesh_client/src/rust/frb_generated.dart';

Future<void> main(List<String> args) async {
  final input =
      jsonDecode(File(args.single).readAsStringSync()) as Map<String, dynamic>;
  await RustLib.init(
    externalLibrary: ExternalLibrary.open(input['library'] as String),
  );
  final store = await NativeClient.open(
    path: input['path'] as String,
    passphrase: input['passphrase'] as String,
  );
  final context = SecurityContext(withTrustedRoots: true)
    ..setTrustedCertificates(input['cert'] as String);
  final http = HttpClient(context: context);
  var profile = {
    ...Map<String, dynamic>.from(input['session'] as Map),
    'endpoint': input['endpoint'],
  };
  await store.execute(
    request: jsonEncode({'op': 'profile_put', 'profile': profile}),
  );
  var rotations = 0;
  final session = AccountSession(
    http: http,
    endpoint: Uri.parse(input['endpoint'] as String),
    profile: () => profile,
    prepareRefresh: () async =>
        (jsonDecode(
              await store.execute(
                request: jsonEncode({
                  'op': 'refresh_prepare',
                  'endpoint': input['endpoint'],
                }),
              ),
            ) as Map)['request']
            as Map<String, dynamic>,
    commitRefresh: (updated) async {
      rotations++;
      profile =
          (jsonDecode(
                await store.execute(
                  request: jsonEncode({
                    'op': 'refresh_complete',
                    'response': updated,
                  }),
                ),
              ) as Map)['profile']
              as Map<String, dynamic>;
    },
  );
  try {
    final responses = await Future.wait(
      List.generate(8, (_) => session.request('/v1/users/me')),
    );
    if (rotations != 1 ||
        responses.any((r) => r['deviceId'] != input['device'])) {
      throw StateError('SESSION_ROTATION_RACE');
    }
    final saved = jsonDecode(
      await store.execute(request: jsonEncode({'op': 'profile'})),
    ) as Map;
    if (saved['refreshToken'] != profile['refreshToken']) {
      throw StateError('SESSION_NOT_DURABLE');
    }
    session.close();
    var denied = false;
    try {
      await session.request('/v1/users/me');
    } catch (_) {
      denied = true;
    }
    if (!denied) throw StateError('CLOSED_SESSION_USED');
    stdout.writeln(
      'PASS: eight actual concurrent Dart API calls share one rotating refresh; new tokens persisted in SQLCipher before use; closed session denied.',
    );
  } finally {
    session.close();
    http.close(force: true);
    store.dispose();
    RustLib.dispose();
  }
}
