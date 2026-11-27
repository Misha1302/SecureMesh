import 'package:material_ui/material_ui.dart';

/// A view of refreshable, active sessions from a device list already checked
/// against /users/me. Older servers do not distinguish these sessions.
Set<String> otherSessionIds(List<dynamic> devices, String current) => {
  for (final d in devices)
    if (d['id'] is String &&
        d['id'] != current &&
        d['isCurrent'] == false &&
        d['revoked'] == false &&
        d['hasRefreshableSession'] == true)
      d['id'] as String,
};

Future<int> revokeListedDevices(
  Set<String> targets, {
  required Future<void> Function(String) revoke,
  required bool Function() active,
  required Future<List<dynamic>?> Function() refresh,
}) async {
  final confirmed = <String>{};
  for (final id in targets) {
    if (!active()) break;
    try {
      await revoke(id);
      confirmed.add(id);
    } catch (_) {
      // A missing response is ambiguous. Reconcile against the final server list.
    }
  }
  if (active()) {
    final list = await refresh();
    if (list != null) {
      for (final d in list) {
        if (d['revoked'] == true && targets.contains(d['id']))
          confirmed.add(d['id'] as String);
      }
    }
  }
  return confirmed.length;
}

class OtherSessionsAction extends StatelessWidget {
  const OtherSessionsAction({
    super.key,
    required this.devices,
    required this.current,
    required this.russian,
    required this.run,
  });
  final List<dynamic> devices;
  final String current;
  final bool russian;
  final Future<int> Function(Set<String>)? run;
  String tr(String ru, String en) => russian ? ru : en;

  @override
  Widget build(BuildContext context) {
    final ids = otherSessionIds(devices, current);
    if (ids.isEmpty) return const SizedBox.shrink();
    final title = tr('Завершить остальные сессии', 'End other sessions');
    return ListTile(
      leading: const Icon(Icons.phonelink_erase),
      title: Text(title),
      onTap: run == null
          ? null
          : () async {
              final messenger = ScaffoldMessenger.of(context);
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(title),
                  content: Text(
                    tr(
                      'Будет отозван доступ других устройств с действующими сессиями (${ids.length}). Для повторного подключения потребуется настроить новое устройство. Уже сохранённые сообщения останутся на этих устройствах.',
                      'This revokes access for the other devices with valid sessions (${ids.length}). Reconnecting requires enrolling a new device. Messages already saved on those devices remain accessible.',
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(tr('Отмена', 'Cancel')),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(tr('Завершить', 'End sessions')),
                    ),
                  ],
                ),
              );
              if (confirmed != true || !context.mounted) return;
              final count = await run!(ids);
              if (!messenger.mounted || count < 0) return;
              final text = count == ids.length
                  ? tr(
                      'Доступ отозван у устройств: $count.',
                      'Access revoked for $count devices.',
                    )
                  : tr(
                      'Отзыв подтверждён для $count из ${ids.length} устройств. Обновите список и повторите для остальных.',
                      'Revocation confirmed for $count of ${ids.length} devices. Refresh the list and retry the remaining devices.',
                    );
              messenger.showSnackBar(SnackBar(content: Text(text)));
            },
    );
  }
}
