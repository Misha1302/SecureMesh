import 'package:material_ui/material_ui.dart';

typedef ChatFolderMap = Map<String, List<String>>;

ChatFolderMap readChatFolders(Object? value) {
  if (value is! Map) return {};
  return {
    for (final entry in value.entries)
      if (entry.key is String && entry.value is List)
        entry.key as String: (entry.value as List).whereType<String>().toList(),
  };
}

class ChatFolderPicker extends StatefulWidget {
  const ChatFolderPicker(this.folders, this.chat, this.tr, {super.key});

  final ChatFolderMap folders;
  final String chat;
  final String Function(String, String) tr;

  @override
  State<ChatFolderPicker> createState() => _ChatFolderPickerState();
}

class _ChatFolderPickerState extends State<ChatFolderPicker> {
  final name = TextEditingController();
  late final selected = {
    for (final entry in widget.folders.entries)
      if (entry.value.contains(widget.chat)) entry.key,
  };

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  void save() {
    final added = name.text.trim();
    if (added.isNotEmpty) selected.add(added);
    final result = <String, List<String>>{};
    for (final folder in {...widget.folders.keys, ...selected}) {
      final members = {...?widget.folders[folder]}..remove(widget.chat);
      if (selected.contains(folder)) members.add(widget.chat);
      if (members.isNotEmpty) result[folder] = members.toList();
    }
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    return AlertDialog(
      title: Text(tr('Папки чата', 'Chat folders')),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final folder in widget.folders.keys)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(folder),
              value: selected.contains(folder),
              onChanged: (yes) => setState(() {
                if (yes == true) {
                  selected.add(folder);
                } else {
                  selected.remove(folder);
                }
              }),
            ),
          TextField(
            controller: name,
            maxLength: 40,
            onSubmitted: (_) => save(),
            decoration: InputDecoration(
              labelText: tr('Новая папка', 'New folder'),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('Отмена', 'Cancel')),
        ),
        FilledButton(onPressed: save, child: Text(tr('Сохранить', 'Save'))),
      ],
    );
  }
}
