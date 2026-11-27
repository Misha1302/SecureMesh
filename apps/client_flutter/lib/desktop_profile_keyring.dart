import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'linux_profile_keyring.dart';

class DesktopProfileKeyring {
  static const channel = MethodChannel('securemesh/windows-profile');
  static bool get supported => Platform.isLinux || Platform.isWindows;

  static Future<String> _id(String path) async {
    final file = File(path);
    if (!path.toLowerCase().endsWith('.db') || !await file.exists()) {
      throw StateError('profile');
    }
    return sha256
        .convert(utf8.encode(await file.resolveSymbolicLinks()))
        .toString();
  }

  static Future<String> status(String path) async {
    if (Platform.isLinux) return LinuxProfileKeyring.status(path);
    if (!Platform.isWindows) return 'unavailable';
    try {
      return await channel.invokeMethod<String>('status', {
            'id': await _id(path),
          }) ??
          'unavailable';
    } catch (_) {
      return 'unavailable';
    }
  }

  static Future<void> enable(
    String path,
    String device,
    String passphrase,
  ) async {
    if (Platform.isLinux) {
      return LinuxProfileKeyring.enable(path, device, passphrase);
    }
    await channel.invokeMethod<void>('enable', {
      'id': await _id(path),
      'deviceId': device,
      'passphrase': passphrase,
    });
  }

  static Future<Map<String, String>> unlock(String path) async {
    if (Platform.isLinux) return LinuxProfileKeyring.unlock(path);
    final secret = await channel.invokeMapMethod<String, String>('unlock', {
      'id': await _id(path),
    });
    if (secret == null) throw StateError('credential');
    return secret;
  }

  static Future<void> forget(String path) async {
    if (Platform.isLinux) return LinuxProfileKeyring.forget(path);
    await channel.invokeMethod<void>('forget', {'id': await _id(path)});
  }
}
