import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// The session's Secret Service can release this credential to other authorized
/// desktop programs. This is an explicit desktop convenience, not biometric auth.
class LinuxProfileKeyring {
  static const _secretTool = '/usr/bin/secret-tool';
  static const _gdbus = '/usr/bin/gdbus';
  static const _application = 'org.securemesh.profile.v1';
  static const _service = '/org/freedesktop/secrets';

  static Future<String> _id(String path) async {
    final db = File(path);
    if (!path.endsWith('.db') || !await db.exists()) {
      throw StateError('profile');
    }
    return sha256
        .convert(utf8.encode(await db.resolveSymbolicLinks()))
        .toString();
  }

  static Future<String> _run(
    String tool,
    List<String> args, {
    String? input,
  }) async {
    final process = await Process.start(tool, args);
    try {
      final output = process.stdout.transform(utf8.decoder).join();
      final drain = process.stderr.drain<void>();
      if (input != null) process.stdin.add(utf8.encode(input));
      await process.stdin.close();
      final values = await Future.wait<Object?>([
        output,
        drain.then<Object?>((_) => null),
        process.exitCode,
      ]).timeout(const Duration(seconds: 45));
      if (values.last != 0) throw StateError('keyring');
      return values.first as String;
    } finally {
      process.kill();
    }
  }

  static Future<String> _call(String path, String method, List<String> args) =>
      _run(_gdbus, [
        'call',
        '--session',
        '--timeout',
        '5',
        '--dest',
        'org.freedesktop.secrets',
        '--object-path',
        path,
        '--method',
        method,
        ...args,
      ]);

  static Future<bool> _hasItem(String id) async {
    final result = await _call(
      _service,
      'org.freedesktop.Secret.Service.SearchItems',
      ["{'application':'$_application','profile':'$id'}"],
    );
    return result.contains('/org/freedesktop/secrets/collection/');
  }

  static Future<String> status(String path) async {
    try {
      if (!Platform.isLinux || !await File(_secretTool).exists()) {
        return 'unavailable';
      }
      final id = await _id(path);
      if (await _hasItem(id)) return 'enrolled';
      final alias = await _call(
        _service,
        'org.freedesktop.Secret.Service.ReadAlias',
        ['default'],
      );
      final collection = RegExp(
        r"'(/org/freedesktop/secrets/collection/[A-Za-z0-9_]+)'",
      ).firstMatch(alias)?.group(1);
      if (collection == null) return 'unavailable';
      final locked = await _call(
        collection,
        'org.freedesktop.DBus.Properties.Get',
        ['org.freedesktop.Secret.Collection', 'Locked'],
      );
      return locked.trim() == '(<false>,)' ? 'available' : 'unavailable';
    } catch (_) {
      return 'unavailable';
    }
  }

  static List<String> _attributes(String id) => [
    'application',
    _application,
    'profile',
    id,
  ];

  static Future<void> enable(
    String path,
    String device,
    String passphrase,
  ) async {
    if (passphrase.isEmpty ||
        !RegExp(
          r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
        ).hasMatch(device)) {
      throw StateError('profile');
    }
    final id = await _id(path);
    if (await status(path) != 'available') throw StateError('keyring');
    await _run(
      _secretTool,
      ['store', '--label=SecureMesh profile unlock', ..._attributes(id)],
      input: jsonEncode({
        'profile': id,
        'deviceId': device,
        'passphrase': passphrase,
      }),
    );
  }

  static Future<Map<String, String>> unlock(String path) async {
    final id = await _id(path);
    final raw = await _run(_secretTool, ['lookup', ..._attributes(id)]);
    final value = jsonDecode(raw);
    if (value is! Map ||
        value['profile'] != id ||
        value['deviceId'] is! String ||
        value['passphrase'] is! String) {
      throw StateError('profile');
    }
    return {'deviceId': value['deviceId'], 'passphrase': value['passphrase']};
  }

  static Future<void> forget(String path) async {
    // "clear" removes matching unlocked entries. Check both locked and unlocked
    // matches afterwards before reporting that the binding was removed.
    final id = await _id(path);
    if (!await _hasItem(id)) return;
    await _run(_secretTool, ['clear', ..._attributes(id)]);
    if (await _hasItem(id)) {
      throw StateError('keyring');
    }
  }
}
