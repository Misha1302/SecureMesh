import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:securemesh_client/profile_files.dart';

void main() {
  test('scanner preserves original paths, skips sidecars and empty files, and reopens local labels', () async {
    final dir = await Directory.systemTemp.createTemp('sm-profile-list-');
    try {
      final file = await File('${dir.path}/0123456789abcdef0123456789abcdef.DB')
          .writeAsBytes(List.filled(128, 7));
      await File('${dir.path}/temporary.db-wal').writeAsString('sidecar');
      await File('${dir.path}/empty.db').create();
      final initial = (await localProfiles(location: dir)).single;
      expect(
        await FileSystemEntity.identical(initial.file.path, file.path),
        isTrue,
      );
      expect(initial.title(true), contains('012345'));
      await setProfileLabel(file, dir, 'Рабочий 🌱');
      expect(
        (await localProfiles(location: dir)).single.title(true),
        'Рабочий 🌱',
      );
      await setProfileLabel(file, dir, '');
      expect((await localProfiles(location: dir)).single.alias, isNull);
      expect(await file.length(), 128);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
