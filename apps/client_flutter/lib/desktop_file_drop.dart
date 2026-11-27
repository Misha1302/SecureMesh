import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const desktopDropChannel = MethodChannel('securemesh/file-drop');
const maxDroppedFiles = 8;

Future<List<XFile>> localDroppedFiles(List<dynamic> paths) async {
  if (paths.isEmpty || paths.length > maxDroppedFiles) return [];
  final files = <XFile>[];
  for (final path in paths.toSet()) {
    if (path is! String ||
        path.length > 32767 ||
        path.contains('\u0000') ||
        !(Platform.isWindows
            ? RegExp(r'^[A-Za-z]:\\').hasMatch(path)
            : path.startsWith('/') && !path.startsWith('//'))) {
      return [];
    }
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return [];
    }
    files.add(XFile(path));
  }
  return files;
}

/// A registered handler exists only while a private composer is mounted.
class DesktopFileDrop extends StatefulWidget {
  const DesktopFileDrop({
    super.key,
    required this.onFiles,
    required this.child,
  });
  final Future<void> Function(List<dynamic>)? onFiles;
  final Widget child;

  @override
  State<DesktopFileDrop> createState() => _DesktopFileDropState();
}

class _DesktopFileDropState extends State<DesktopFileDrop> {
  @override
  void initState() {
    super.initState();
    if (Platform.isLinux || Platform.isWindows) {
      desktopDropChannel.setMethodCallHandler((call) async {
        if (mounted &&
            ModalRoute.of(context)?.isCurrent == true &&
            call.method == 'drop' &&
            call.arguments is List) {
          await widget.onFiles?.call(call.arguments as List<dynamic>);
        }
      });
    }
  }

  @override
  void dispose() {
    if (Platform.isLinux || Platform.isWindows) {
      desktopDropChannel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
