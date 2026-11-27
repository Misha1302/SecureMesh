import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'attachment_transfer.dart';

class AttachmentSelection extends StatefulWidget {
  const AttachmentSelection(this.files, this.tr, {super.key});
  final List<XFile> files;
  final String Function(String, String) tr;
  @override
  State<AttachmentSelection> createState() => _AttachmentSelectionState();
}

class _AttachmentSelectionState extends State<AttachmentSelection> {
  late final files = [...widget.files];
  final caption = TextEditingController();
  @override
  void dispose() {
    caption.dispose();
    super.dispose();
  }

  void submit() {
    if (files.isNotEmpty && utf8.encode(caption.text.trim()).length <= 2048) {
      Navigator.pop(context, (files: files, caption: caption.text.trim()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): submit,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): submit,
      },
      child: AlertDialog(
        title: Text(
          files.length == 1
              ? tr('Отправить файл?', 'Send this file?')
              : tr('Отправить файлы?', 'Send these files?'),
        ),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final file in files)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.insert_drive_file_outlined),
                    title: Text(attachmentName(file.name)),
                    trailing: IconButton(
                      tooltip: tr(
                        'Убрать из отправки',
                        'Remove from selection',
                      ),
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => files.remove(file)),
                    ),
                  ),
                TextField(
                  controller: caption,
                  onChanged: (_) => setState(() {}),
                  maxLength: 256,
                  maxLines: 2,
                  minLines: 1,
                  decoration: InputDecoration(
                    errorText: utf8.encode(caption.text.trim()).length > 2048
                        ? tr('Сократите подпись', 'Shorten the caption')
                        : null,
                    labelText: files.length > 1
                        ? tr('Подпись к первому файлу', 'Caption on first file')
                        : tr('Подпись', 'Caption'),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('Отмена', 'Cancel')),
          ),
          FilledButton(
            autofocus: true,
            onPressed:
                files.isEmpty || utf8.encode(caption.text.trim()).length > 2048
                ? null
                : submit,
            child: Text(tr('Отправить', 'Send')),
          ),
        ],
      ),
    );
  }
}
