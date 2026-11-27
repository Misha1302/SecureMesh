import 'package:material_ui/material_ui.dart';

class DeviceTile extends StatelessWidget {
  const DeviceTile({
    super.key,
    required this.device,
    required this.current,
    required this.russian,
    required this.onRevoke,
  });

  final Map device;
  final bool current, russian;
  final VoidCallback? onRevoke;

  String tr(String ru, String en) => russian ? ru : en;

  @override
  Widget build(BuildContext context) {
    final id = device['id'] as String;
    final revoked = device['revoked'] == true;
    final trusted = device['trustState'] == 'DEVICE_TRUSTED';
    return ListTile(
      leading: const Icon(Icons.devices_outlined),
      title: Text(
        current
            ? tr('Это устройство', 'This device')
            : tr('Другое устройство', 'Other device'),
      ),
      subtitle: Text(
        revoked
            ? tr('Отозвано', 'Revoked')
            : trusted
            ? tr('Доверенное', 'Trusted')
            : tr('Ожидает подтверждения', 'Awaiting approval'),
      ),
      onTap: () => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('Идентификатор устройства', 'Device identifier')),
          content: SelectableText(id),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Закрыть', 'Close')),
            ),
          ],
        ),
      ),
      trailing: current || revoked
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
