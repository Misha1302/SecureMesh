import 'package:material_ui/material_ui.dart';

import 'display_name.dart';

class DeviceTile extends StatelessWidget {
  const DeviceTile({
    super.key,
    required this.device,
    required this.current,
    required this.russian,
    required this.onRevoke,
    this.localOs,
    this.onRename,
  });

  final Map device;
  final bool current, russian;
  final VoidCallback? onRevoke;
  final String? localOs;
  final Future<void> Function(String name)? onRename;

  String tr(String ru, String en) => russian ? ru : en;

  @override
  Widget build(BuildContext context) {
    final id = device['id'] as String;
    final revoked = device['revoked'] == true;
    final trusted = device['trustState'] == 'DEVICE_TRUSTED';
    final (os, glyph) = switch (current && localOs != null
        ? localOs
        : device['clientOs']) {
      'android' => ('Android', Icons.android),
      'ios' => ('iOS', Icons.phone_iphone),
      'linux' => ('Linux', Icons.computer),
      'windows' => ('Windows', Icons.desktop_windows),
      'macos' => ('macOS', Icons.laptop_mac),
      _ => (null, Icons.devices_outlined),
    };
    final name = peerDisplayName(device['name']);
    final role = current
        ? tr('Это устройство', 'This device')
        : tr('Другое устройство', 'Other device');
    final label = name ?? os ?? role;
    final trust = revoked
        ? tr('Отозвано', 'Revoked')
        : trusted
        ? tr('Доверенное', 'Trusted')
        : tr('Ожидает подтверждения', 'Awaiting approval');
    String? date(Object? raw) {
      final value = raw is String ? DateTime.tryParse(raw)?.toLocal() : null;
      if (value == null) return null;
      final loc = MaterialLocalizations.of(context);
      return '${loc.formatCompactDate(value)} · ${loc.formatTimeOfDay(TimeOfDay.fromDateTime(value), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}';
    }

    final created = date(device['createdAt']),
        login = date(device['lastLoginAt']);
    return ListTile(
      leading: Icon(glyph),
      title: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != role) Text(role),
          Text(trust),
          if (created != null) Text(tr('Добавлено $created', 'Added $created')),
        ],
      ),
      onTap: () => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(label),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(role),
                Text(trust),
                if (os != null)
                  Text(
                    tr('ОС по данным приложения: $os', 'App-reported OS: $os'),
                  ),
                if (name != null)
                  Text(
                    tr(
                      'Имя, указанное пользователем: $name',
                      'User-provided name: $name',
                    ),
                  ),
                if (created != null)
                  Text(
                    tr(
                      'Устройство добавлено: $created',
                      'Device added: $created',
                    ),
                  ),
                if (login != null)
                  Text(
                    tr(
                      'Последний вход с паролем: $login',
                      'Last password sign-in: $login',
                    ),
                  ),
                if (!revoked && device['hasRefreshableSession'] is bool)
                  Text(
                    device['hasRefreshableSession'] == true
                        ? tr('Есть действующая сессия', 'Has a valid session')
                        : tr('Действующих сессий нет', 'No valid sessions'),
                  ),
                const SizedBox(height: 12),
                Text(tr('Идентификатор устройства', 'Device identifier')),
                SelectableText(id),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Закрыть', 'Close')),
            ),
          ],
        ),
      ),
      trailing: current && !revoked && onRename != null
          ? IconButton(
              tooltip: tr('Изменить имя устройства', 'Rename device'),
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => _DeviceNameDialog(
                  name: name ?? '',
                  russian: russian,
                  save: onRename!,
                ),
              ),
            )
          : current || revoked
          ? null
          : IconButton(
              tooltip: tr('Отозвать доступ', 'Revoke access'),
              icon: const Icon(Icons.phonelink_erase),
              onPressed: onRevoke == null
                  ? null
                  : () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: Text(
                            tr(
                              'Отозвать доступ устройства?',
                              'Revoke device access?',
                            ),
                          ),
                          content: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SelectableText(id),
                                const SizedBox(height: 12),
                                Text(
                                  tr(
                                    'Сервер прекратит обмен с этим устройством. Сохранённые на нём сообщения останутся доступны.',
                                    'The server will stop communicating with this device. Messages already saved on it remain available.',
                                  ),
                                ),
                              ],
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: Text(tr('Отмена', 'Cancel')),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: Text(tr('Отозвать', 'Revoke')),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true && context.mounted) {
                        onRevoke?.call();
                      }
                    },
            ),
    );
  }
}

class _DeviceNameDialog extends StatefulWidget {
  const _DeviceNameDialog({
    required this.name,
    required this.russian,
    required this.save,
  });
  final String name;
  final bool russian;
  final Future<void> Function(String name) save;
  @override
  State<_DeviceNameDialog> createState() => _DeviceNameState();
}

class _DeviceNameState extends State<_DeviceNameDialog> {
  late final controller = TextEditingController(text: widget.name);
  bool busy = false;
  String? error;
  String tr(String ru, String en) => widget.russian ? ru : en;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final value = controller.text.trim();
    if (busy) return;
    if (value.isNotEmpty && peerDisplayName(value) == null) {
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
      await widget.save(value);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted)
        setState(() {
          busy = false;
          error = tr(
            'Не удалось сохранить имя.',
            'Could not save device name.',
          );
        });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('Имя устройства', 'Device name')),
    content: TextField(
      controller: controller,
      autofocus: true,
      enabled: !busy,
      maxLength: 64,
      onSubmitted: (_) => save(),
      decoration: InputDecoration(errorText: error),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: Text(tr('Отмена', 'Cancel')),
      ),
      FilledButton(
        onPressed: busy ? null : save,
        child: Text(tr('Сохранить', 'Save')),
      ),
    ],
  );
}
