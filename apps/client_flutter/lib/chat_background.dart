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

const _dimmingLevels = [0, 10, 20];

int? _savedDimming(Map? profile, String? group, bool dark) {
  final values = profile?['chatDimming'];
  final value = values is Map ? values[_key(group, dark)] : null;
  return value is int && _dimmingLevels.contains(value) ? value : null;
}

int chatDimming(Map? profile, String? group, bool dark) =>
    _savedDimming(profile, group, dark) ??
    _savedDimming(profile, null, dark) ??
    0;

Map<String, dynamic> updateChatDimming(
  Map? profile,
  String? group,
  bool dark,
  int? value,
) {
  final old = profile?['chatDimming'];
  final next = old is Map
      ? Map<String, dynamic>.from(old)
      : <String, dynamic>{};
  if (value == null) {
    next.remove(_key(group, dark));
  } else {
    if (!_dimmingLevels.contains(value)) throw ArgumentError.value(value);
    next[_key(group, dark)] = value;
  }
  return next;
}

Color chatBackgroundColor(ColorScheme scheme, String value, {int dimming = 0}) {
  final base = switch (value) {
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
  return Color.alphaBlend(Colors.black.withValues(alpha: dimming / 100), base);
}

class ChatBackgroundSettings extends StatelessWidget {
  const ChatBackgroundSettings({
    super.key,
    required this.profile,
    required this.group,
    required this.name,
    required this.tr,
    required this.save,
    required this.saveDimming,
  });
  final Map? profile;
  final String? group, name;
  final String Function(String, String) tr;
  final void Function(String?, bool, String?) save;

  final void Function(String?, bool, int?) saveDimming;

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
      final dimming = chatDimming(profile, id, dark);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
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
                      dimming: dimming,
                    ),
                  ),
                  onSelected: (_) => save(id, dark, _colors[i]),
                ),
            ],
          ),
          DropdownButtonFormField<int>(
            key: ValueKey((
              id,
              dark,
              dimming,
              _savedDimming(profile, id, dark),
            )),
            decoration: InputDecoration(
              labelText: tr('Затемнение фона', 'Background dimming'),
            ),
            initialValue: id == null
                ? dimming
                : _savedDimming(profile, id, dark) ?? -1,
            items: [
              if (id != null)
                DropdownMenuItem(
                  value: -1,
                  child: Text(tr('Как у всех чатов', 'Use global dimming')),
                ),
              for (final level in _dimmingLevels)
                DropdownMenuItem(value: level, child: Text('$level%')),
            ],
            onChanged: (level) {
              if (level != null) {
                saveDimming(id, dark, level == -1 ? null : level);
              }
            },
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
