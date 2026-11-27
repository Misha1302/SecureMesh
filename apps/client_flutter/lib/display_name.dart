import 'dart:convert';

import 'package:material_ui/material_ui.dart';

typedef DisplayNameApi = Future<dynamic> Function(
  String route, {
  Map<String, dynamic>? data,
  String? method,
});

// The directory supplies a presentation label only. Ignore unsafe or malformed
// labels even if a directory other than the bundled server supplies them.
final _unsafeLabel = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u2028-\u202e\u2066-\u2069]',
);

String? peerDisplayName(Object? value) {
  if (value is! String ||
      value.characters.length > 64 ||
      utf8.encode(value).length > 2048 ||
      _unsafeLabel.hasMatch(value)) {
    return null;
  }
  final name = value.trim();
  return name.isEmpty ? null : name;
}

class DisplayNameEditor extends StatefulWidget {
  const DisplayNameEditor({
    super.key,
    required this.api,
    required this.russian,
  });

  final DisplayNameApi api;
  final bool russian;

  @override
  State<DisplayNameEditor> createState() => _DisplayNameEditorState();
}

class _DisplayNameEditorState extends State<DisplayNameEditor> {
  final controller = TextEditingController();
  bool busy = true;
  bool loaded = false;
  String? error;

  String tr(String ru, String en) => widget.russian ? ru : en;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final me = await widget.api('/v1/users/me') as Map;
      if (!mounted) return;
      if (!me.containsKey('displayName')) {
        throw StateError('Unsupported server');
      }
      controller.text = peerDisplayName(me['displayName']) ?? '';
      loaded = true;
    } catch (_) {
      if (!mounted) return;
      error = tr(
        'Не удалось прочитать профиль. Проверьте сеть и версию сервера.',
        'Could not read your profile. Check the network and server version.',
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    final input = controller.text;
    if (input.characters.length > 64 ||
        utf8.encode(input).length > 2048 ||
        _unsafeLabel.hasMatch(input)) {
      setState(
        () => error = tr(
          'Введите до 64 символов в одну строку.',
          'Use up to 64 characters on one line.',
        ),
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.api(
        '/v1/users/me/display-name',
        method: 'PUT',
        data: {'displayName': input.trim()},
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        busy = false;
        error = tr(
          'Не удалось сохранить имя. Проверьте ввод и соединение.',
          'Could not save your name. Check the text and connection.',
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('Отображаемое имя', 'Display name')),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) const LinearProgressIndicator(),
          if (loaded)
            TextField(
              controller: controller,
              enabled: !busy,
              maxLength: 64,
              decoration: InputDecoration(
                labelText: tr('Имя', 'Name'),
                helperText: tr(
                  'Любые письменности, эмодзи, пробелы и знаки. Имя видно собеседникам и серверу. Очистите поле, чтобы убрать имя.',
                  'Use any script, emoji, spaces and punctuation. Contacts and the server can see this name. Clear the field to remove it.',
                ),
                helperMaxLines: 3,
              ),
            ),
          if (error != null) Semantics(liveRegion: true, child: Text(error!)),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr('Закрыть', 'Close')),
      ),
      if (!busy && !loaded)
        TextButton(onPressed: load, child: Text(tr('Повторить', 'Retry'))),
      if (loaded)
        FilledButton(
          onPressed: busy ? null : save,
          child: Text(tr('Сохранить', 'Save')),
        ),
    ],
  );
}
