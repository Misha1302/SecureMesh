import 'dart:io';

import 'package:path_provider/path_provider.dart';

Future<Directory> localProfileDirectory() async {
  final location = Platform.environment['SECUREMESH_PROFILE_DIRECTORY'];
  return location == null
      ? getApplicationSupportDirectory()
      : Directory(location);
}

/// Filenames disclose only random identifiers; account labels require unlock.
Future<List<File>> localProfiles() async {
  final directory = await localProfileDirectory();
  if (!await directory.exists()) return [];
  final files = await directory
      .list(followLinks: false)
      .where((entry) => entry is File && entry.path.endsWith('.db'))
      .take(128)
      .cast<File>()
      .toList();
  final modified = <String, DateTime>{};
  for (final file in files) {
    modified[file.path] = (await file.stat()).modified;
  }
  files.sort((a, b) => modified[b.path]!.compareTo(modified[a.path]!));
  return files;
}
