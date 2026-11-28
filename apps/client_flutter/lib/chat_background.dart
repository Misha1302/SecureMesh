import 'package:material_ui/material_ui.dart';

String _key(String? group, bool dark) =>
    '${group ?? 'global'}/${dark ? 'dark' : 'light'}';

const _colors = ['default', 'blue', 'mint'];

String? _choice(Map? profile, String? group, bool dark) {
  final saved = profile?['chatBackgrounds'];
  final value = saved is Map ? saved[_key(group, dark)] : null;
  return _colors.contains(value) ? value as String : null;
}

String chatBackground(Map? profile, String? group, bool dark) =>
    _choice(profile, group, dark) ??
    _choice(profile, null, dark) ??
    (_colors.contains(profile?['chatBackground'])
        ? profile!['chatBackground'] as String
        : 'default');

Map<String, dynamic> updateChatBackground(
  Map? profile,
  String? group,
  bool dark,
  String? color,
) {
  final old = profile?['chatBackgrounds'];
  final next = old is Map
      ? Map<String, dynamic>.from(old)
      : <String, dynamic>{};
  final key = _key(group, dark);
  if (color == null) {
    next.remove(key);
  } else {
    if (!_colors.contains(color)) throw ArgumentError.value(color);
    next[key] = color;
  }
  return next;
}

Color chatBackgroundColor(ColorScheme scheme, String value) => switch (value) {
  'blue' => Color.alphaBlend(
    scheme.primary.withValues(alpha: .085),
    scheme.surface,
  ),
  'mint' => Color.alphaBlend(
    const Color(0xff439779).withValues(alpha: .13),
    scheme.surface,
  ),
  _ => scheme.surface,
};

class ChatBackgroundSettings extends StatelessWidget {
  const ChatBackgroundSettings({
    super.key,
    required this.profile,
    required this.group,
    required this.name,
    required this.tr,
    required this.save,
  });
  final Map? profile;
  final String? group, name;
  final String Function(String, String) tr;
  final void Function(String?, bool, String?) save;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final labels = [
      tr('Обычный', 'Default'),
      tr('Голубой', 'Blue'),
      tr('Мятный', 'Mint'),
    ];
    Widget options(String? id) {
      final selected = id == null
          ? chatBackground(profile, id, dark)
          : _choice(profile, id, dark);
      return Wrap(
        spacing: 8,
        children: [
          if (id != null)
            ChoiceChip(
              label: Text(tr('Как у всех чатов', 'Use global setting')),
              selected: selected == null,
              onSelected: (_) => save(id, dark, null),
            ),
          for (var i = 0; i < _colors.length; i++)
            ChoiceChip(
              label: Text(labels[i]),
              selected: selected == _colors[i],
              avatar: CircleAvatar(
                backgroundColor: chatBackgroundColor(
                  Theme.of(context).colorScheme,
                  _colors[i],
                ),
              ),
              onSelected: (_) => save(id, dark, _colors[i]),
            ),
        ],
      );
    }

    return Column(
      children: [
        ListTile(
          title: Text(tr('Фон переписки', 'Chat background')),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                dark
                    ? tr('Все чаты · тёмная тема', 'All chats · dark theme')
                    : tr('Все чаты · светлая тема', 'All chats · light theme'),
              ),
              options(null),
            ],
          ),
        ),
        if (group != null && name != null)
          ListTile(
            title: Text(tr('Фон чата с @$name', 'Background for @$name')),
            subtitle: options(group),
          ),
      ],
    );
  }
}
