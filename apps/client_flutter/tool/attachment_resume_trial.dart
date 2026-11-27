import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:securemesh_client/attachment_transport.dart';
import 'package:securemesh_client/local_client.dart';
import 'package:securemesh_client/session.dart';
import 'package:securemesh_client/src/rust/api.dart';
import 'package:securemesh_client/src/rust/frb_generated.dart';

class Interrupted implements Exception {}

Future<void> main(List<String> args) async {
  final fixture = jsonDecode(await File(args[0]).readAsString());
  final first = args[1] == 'interrupt';
  await RustLib.init(externalLibrary: ExternalLibrary.open(fixture['library']));
  final store = await NativeClient.open(
    path: fixture['database'],
    passphrase: fixture['passphrase'],
  );
  Future<Map<String, dynamic>> command(
    String op,
    Map<String, dynamic> fields,
  ) async => jsonDecode(
    await store.execute(request: jsonEncode({'op': op, ...fields})),
  ) as Map<String, dynamic>;
  final http = nativeHttpClient();
  final session = AccountSession(
    http: http,
    endpoint: Uri.parse(fixture['endpoint']),
    profile: () => {'accessToken': fixture['token']},
    persist: (_) async {
      throw StateError('Unexpected rotation');
    },
  );
  final transport = SessionBlobs(session, fixture['group'], command);
  final sealed = await File(fixture['sealed']).readAsBytes();
  Future<void> phase(
    Future<void> Function(void Function(double)) action,
  ) async {
    var reports = 0;
    try {
      await action((fraction) {
        final offset = (fraction * sealed.length).round();
        if (reports++ == 0 && offset != (first ? 0 : 32768)) {
          throw StateError('Unexpected initial checkpoint');
        }
        if (first && offset == 32768) throw Interrupted();
      });
      if (first) throw StateError('Transfer did not stop');
    } on Interrupted {
      if (!first) rethrow;
    }
  }

  try {
    await phase((report) => transport.put(fixture['extra'], sealed, report));
    Uint8List? bytes;
    await phase((report) async {
      bytes = await transport.get(
        fixture['message'],
        fixture['blob'],
        sealed.length,
        report,
      );
    });
    if (!first) {
      final opened = await command('attachment_open', {
        'group': fixture['group'],
        'id': fixture['message'],
        'ciphertext': base64Encode(bytes!),
      });
      if (sha256.convert(base64Decode(opened['data'])).toString() !=
          fixture['clearDigest']) {
        throw StateError('Restored attachment differs');
      }
    }
  } finally {
    transport.close();
    session.close();
    http.close(force: true);
    store.dispose();
  }
}
