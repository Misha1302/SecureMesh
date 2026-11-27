import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

Future<Directory> localProfileDirectory() async {
  final location = Platform.environment['SECUREMESH_PROFILE_DIRECTORY'];
  return location == null
      ? getApplicationSupportDirectory()
      : Directory(location);
}

class ProfileFileInfo {
  const ProfileFileInfo(this.file, this.modified, this.bytes, this.alias);
  final File file;
  final DateTime modified;
  final int bytes;
  final String? alias;
  String get filename => file.uri.pathSegments.last;

  String title(bool ru) {
    if (alias != null) return alias!;
    final stem = filename.replaceFirst(
      RegExp(r'\.db$', caseSensitive: false),
      '',
    );
    if (RegExp(r'^[a-f0-9-]{30,}$', caseSensitive: false).hasMatch(stem)) {
      return ru
          ? 'Личный профиль · ${stem.substring(0, 6)}'
          : 'Personal profile · ${stem.substring(0, 6)}';
    }
    return stem.replaceAll(
      RegExp(r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]'),
      '�',
    );
  }

  String details(BuildContext context, bool ru) {
    final locale = MaterialLocalizations.of(context);
    final date = locale.formatMediumDate(modified.toLocal());
    final time = locale.formatTimeOfDay(
      TimeOfDay.fromDateTime(modified.toLocal()),
    );
    return '${ru ? "Изменён" : "Modified"} $date, $time · ${(bytes / 1024).ceil()} ${ru ? "КиБ" : "KiB"}';
  }
}

Future<File> _aliasFile(File profile, Directory directory) async {
  final canonical = await profile.resolveSymbolicLinks();
  final id = sha256.convert(utf8.encode(canonical)).toString();
  return File('${directory.path}/profile-labels/$id');
}

Future<ProfileFileInfo?> inspectProfile(File file, Directory directory) async {
  final stat = await file.stat();
  if (stat.type != FileSystemEntityType.file || stat.size < 16) return null;
  String? alias;
  try {
    final label = await _aliasFile(file, directory);
    if (await label.exists() && await label.length() <= 384) {
      final stored = (await label.readAsString()).trim();
      if (stored.isNotEmpty) alias = stored;
    }
  } on FormatException {
    // A corrupted label must not hide an otherwise intact profile.
  } on FileSystemException {
    /* An optional label may have disappeared. */
  }
  return ProfileFileInfo(file, stat.modified, stat.size, alias);
}

Future<void> setProfileLabel(
  File file,
  Directory directory,
  String value,
) async {
  final name = value.trim();
  if (utf8.encode(name).length > 384 ||
      RegExp(r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]')
          .hasMatch(name)) {
    throw const FormatException('Invalid profile label');
  }
  final label = await _aliasFile(file, directory);
  if (name.isEmpty) {
    if (await label.exists()) await label.delete();
    return;
  }
  await label.parent.create(recursive: true);
  final staging = await label.parent.createTemp('label-');
  try {
    final temporary = await File('${staging.path}/name')
        .writeAsString(name, flush: true);
    await temporary.rename(label.path);
  } finally {
    await staging.delete(recursive: true);
  }
}

/// Labels before unlock are user-selected. Account names and keys stay encrypted.
Future<List<ProfileFileInfo>> localProfiles({Directory? location}) async {
  final directory = location ?? await localProfileDirectory();
  if (!await directory.exists()) return [];
  final profiles = <ProfileFileInfo>[];
  await for (final entry in directory.list(followLinks: false)) {
    if (entry is! File || !entry.path.toLowerCase().endsWith('.db')) continue;
    try {
      final info = await inspectProfile(entry, directory);
      if (info != null) profiles.add(info);
    } on FileSystemException {
      /* A removed file does not hide the others. */
    }
  }
  profiles.sort((a, b) {
    final order = b.modified.compareTo(a.modified);
    return order == 0 ? a.file.path.compareTo(b.file.path) : order;
  });
  return profiles;
}
