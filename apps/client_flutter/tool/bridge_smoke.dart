import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:securemesh_client/src/rust/api.dart';
import 'package:securemesh_client/src/rust/frb_generated.dart';

Future<Map<String, dynamic>> call(
  NativeClient store,
  String op,
  Map<String, dynamic> args,
) async =>
    jsonDecode(await store.execute(request: jsonEncode({'op': op, ...args})))
        as Map<String, dynamic>;

Future<void> main() async {
  final root = Directory.current.parent.parent;
  await RustLib.init(
    externalLibrary: ExternalLibrary.open(
      '${root.path}/src/crypto_core/target/debug/libsecuremesh_crypto.so',
    ),
  );
  final directory = Directory('${root.path}/.local/dart-bridge-test')
    ..createSync(recursive: true);
  // Synthetic local passphrase, never written into the repository or logs.
  final pass =
      '${DateTime.now().microsecondsSinceEpoch}-bridge-only-test-unlock';
  final a = await NativeClient.open(
    path: '${directory.path}/a-${DateTime.now().microsecondsSinceEpoch}.db',
    passphrase: pass,
  );
  final b = await NativeClient.open(
    path: '${directory.path}/b-${DateTime.now().microsecondsSinceEpoch}.db',
    passphrase: pass,
  );
  final ai = await call(a, 'init', {'identity': 'dart-a'});
  final bi = await call(b, 'init', {'identity': 'dart-b'});
  await call(a, 'pin', {
    'identity': 'dart-b',
    'public_key': bi['public_key'],
    'confirmed': true,
  });
  await call(b, 'pin', {
    'identity': 'dart-a',
    'public_key': ai['public_key'],
    'confirmed': true,
  });
  await call(a, 'create', {'group': 'dart-ffi-spike'});
  final kp = await call(b, 'keypackage', {});
  final welcome = await call(a, 'add', {
    'group': 'dart-ffi-spike',
    'keypackage': kp['keypackage'],
  });
  await call(b, 'join', {
    'group': 'dart-ffi-spike',
    'welcome': welcome['welcome'],
  });
  final message = await call(a, 'queue', {
    'group': 'dart-ffi-spike',
    'id': '1f40e419-05b1-4378-9d48-b814363a0111',
    'text': 'Dart → Rust → MLS → Rust → Dart',
  });
  final decrypted = await call(b, 'process', {
    'group': 'dart-ffi-spike',
    'ciphertext': message['ciphertext'],
  });
  if (decrypted['text'] != 'Dart → Rust → MLS → Rust → Dart') {
    throw StateError('FFI plaintext mismatch');
  }
  bool rejected = false;
  try {
    await call(b, 'process', {
      'group': 'dart-ffi-spike',
      'ciphertext': message['ciphertext'],
    });
  } catch (_) {
    rejected = true;
  }
  if (!rejected) throw StateError('FFI replay accepted');
  a.dispose();
  b.dispose();
  stdout.writeln(
    'PASS: Dart flutter_rust_bridge 2.13.0 calls native OpenMLS/SQLCipher; two stores, Welcome, Unicode decrypt, replay deny. This is a Linux Dart FFI check, not an Android or Flutter UI run.',
  );
  RustLib.dispose();
}
