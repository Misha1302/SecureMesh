import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:securemesh_client/linux_profile_keyring.dart';
import 'package:securemesh_client/src/rust/api.dart';
import 'package:securemesh_client/src/rust/frb_generated.dart';

void check(bool value, String step) {
  if (!value) throw StateError(step);
}

Future<void> main() async {
  if (Platform.environment['SECUREMESH_ISOLATED_KEYRING'] != '1') {
    throw StateError(
      'Use an isolated dbus-run-session and disposable keyring.',
    );
  }
  await RustLib.init(
    externalLibrary: ExternalLibrary.open(
      Platform.environment['SECUREMESH_CRYPTO_LIB']!,
    ),
  );
  final directory = await Directory.systemTemp.createTemp(
    'securemesh-keyring-',
  );
  final a = '${directory.path}/first.db', b = '${directory.path}/second.db';
  final random = Random.secure();
  final pass = base64Encode(List.generate(32, (_) => random.nextInt(256)));
  const first = '11c13356-bd4a-43cb-b368-b5ef7540af8b';
  const second = '2c1e7f69-2438-4ddb-8a10-88e41fba2632';
  try {
    for (final (path, device) in [(a, first), (b, second)]) {
      final db = await NativeClient.open(path: path, passphrase: pass);
      try {
        await db.execute(
          request: jsonEncode({'op': 'init', 'identity': device}),
        );
        await db.execute(
          request: jsonEncode({
            'op': 'profile_put',
            'profile': {'deviceId': device},
          }),
        );
      } finally {
        db.dispose();
      }
      check(await LinuxProfileKeyring.status(path) == 'available', 'fresh');
      await LinuxProfileKeyring.enable(path, device, pass);
    }
    final wrapped = await LinuxProfileKeyring.unlock(a);
    final db = await NativeClient.open(
      path: a,
      passphrase: wrapped['passphrase']!,
    );
    try {
      final profile = jsonDecode(await db.execute(request: '{"op":"profile"}'));
      check(
        profile['deviceId'] == wrapped['deviceId'] &&
            wrapped['deviceId'] == first,
        'bound profile',
      );
    } finally {
      db.dispose();
    }
    await LinuxProfileKeyring.forget(a);
    check(await LinuxProfileKeyring.status(a) == 'available', 'removed');
    check(
      (await LinuxProfileKeyring.unlock(b))['deviceId'] == second,
      'other profile preserved',
    );
    await LinuxProfileKeyring.forget(b);
    final manual = await NativeClient.open(path: a, passphrase: pass);
    try {
      check(
        jsonDecode(
              await manual.execute(request: '{"op":"profile"}'),
            )['deviceId'] ==
            first,
        'manual',
      );
    } finally {
      manual.dispose();
    }
    stdout.writeln(
      'PASS: Secret Service opt-in, SQLCipher reopen, device binding, isolated removal and manual unlock.',
    );
  } finally {
    await directory.delete(recursive: true);
    RustLib.dispose();
  }
}
