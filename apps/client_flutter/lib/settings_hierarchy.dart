import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'profile_files.dart';

/// Only these two installation preferences are readable before profile unlock.
class AppearancePreferences {
  AppearancePreferences({this.directory = localProfileDirectory});
  final Future<Directory> Function() directory;

  Future<String?> _read(String name) async {
    final file = File('${(await directory()).path}/ui-$name');
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  Future<(ThemeMode?, bool?)> read() async {
    final mode = await _read('theme');
    final language = await _read('language');
    return (
      ThemeMode.values.where((item) => item.name == mode).firstOrNull,
      switch (language) {
        'ru' => true,
        'en' => false,
        _ => null,
      },
    );
  }

  Future<void> _write(String name, String value) async {
    final root = await directory();
    await root.create(recursive: true);
    final temporary = await root.createTemp('.ui-');
    try {
      final file = File('${temporary.path}/value');
      await file.writeAsString(value, flush: true);
      await file.rename('${root.path}/ui-$name');
    } finally {
      await temporary.delete(recursive: true);
    }
  }

  Future<void> saveLanguage(bool russian) =>
      _write('language', russian ? 'ru' : 'en');
  Future<void> saveTheme(ThemeMode mode) => _write('theme', mode.name);
}

enum SettingsSection {
  profile(Icons.person_outline, 'Мой профиль', 'My profile'),
  notifications(Icons.notifications_outlined, 'Уведомления', 'Notifications'),
  privacy(
    Icons.lock_outline,
    'Конфиденциальность и безопасность',
    'Privacy and security',
  ),
  devices(Icons.devices_outlined, 'Устройства', 'Devices'),
  storage(Icons.storage_outlined, 'Данные и память', 'Data and storage'),
  appearance(Icons.palette_outlined, 'Оформление', 'Appearance'),
  language(Icons.language_outlined, 'Язык', 'Language'),
  advanced(Icons.info_outline, 'Дополнительно', 'Advanced');

  const SettingsSection(this.icon, this.ru, this.en);
  final IconData icon;
  final String ru, en;
}

class SettingsHierarchy extends StatefulWidget {
  const SettingsHierarchy({
    super.key,
    required this.russian,
    required this.sections,
    required this.content,
    required this.summary,
  });
  final bool russian;
  final List<SettingsSection> sections;
  final List<Widget> Function(SettingsSection) content;
  final String? Function(SettingsSection) summary;

  @override
  State<SettingsHierarchy> createState() => SettingsHierarchyState();
}

class SettingsHierarchyState extends State<SettingsHierarchy> {
  SettingsSection? selected;

  bool backToMenu() {
    if (selected == null) return false;
    setState(() => selected = null);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.sections.contains(selected) ? selected : null;
    String label(SettingsSection section) =>
        widget.russian ? section.ru : section.en;
    final title = current == null
        ? (widget.russian ? 'Настройки' : 'Settings')
        : label(current);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          key: ValueKey(current),
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 16, 12),
              child: Row(
                children: [
                  if (current != null)
                    BackButton(onPressed: backToMenu)
                  else
                    const SizedBox(width: 4),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        title,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (current == null)
              for (final section in widget.sections)
                ListTile(
                  leading: Icon(section.icon),
                  title: Text(label(section)),
                  subtitle: switch (widget.summary(section)) {
                    final String value => Text(value),
                    null => null,
                  },
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => setState(() => selected = section),
                )
            else
              ...widget.content(current),
          ],
        ),
      ),
    );
  }
}

class ProfileStorageSize extends StatefulWidget {
  const ProfileStorageSize({
    super.key,
    required this.path,
    required this.russian,
  });
  final String path;
  final bool russian;
  @override
  State<ProfileStorageSize> createState() => _ProfileStorageSizeState();
}

class _ProfileStorageSizeState extends State<ProfileStorageSize> {
  late final bytes = File(widget.path).length();
  @override
  Widget build(BuildContext context) => FutureBuilder<int>(
    future: bytes,
    builder: (_, snapshot) => ListTile(
      title: Text(
        widget.russian
            ? 'Файл зашифрованного профиля'
            : 'Encrypted profile file',
      ),
      subtitle: Text(
        snapshot.hasData
            ? '${snapshot.data} ${widget.russian ? 'байт' : 'bytes'}'
            : snapshot.hasError
            ? (widget.russian ? 'Размер недоступен' : 'Size unavailable')
            : (widget.russian ? 'Подсчёт…' : 'Calculating…'),
      ),
    ),
  );
}
