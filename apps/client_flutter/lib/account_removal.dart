import 'package:material_ui/material_ui.dart';

class AccountRemovalDialog extends StatefulWidget {
  const AccountRemovalDialog({
    super.key,
    required this.russian,
    required this.remove,
  });
  final bool russian;
  final Future<void> Function(String password) remove;
  @override
  State<AccountRemovalDialog> createState() => _AccountRemovalDialogState();
}

class _AccountRemovalDialogState extends State<AccountRemovalDialog> {
  final password = TextEditingController();
  bool visible = false;
  bool accepted = false, working = false, failed = false;
  String tr(String ru, String en) => widget.russian ? ru : en;
  @override
  void dispose() {
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (working || !accepted || password.text.isEmpty) return;
    setState(() {
      working = true;
      failed = false;
    });
    try {
      await widget.remove(password.text);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          working = false;
          failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !working,
    child: AlertDialog(
      title: Text(tr('Удалить тестовый аккаунт?', 'Delete lab account?')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tr(
                'Сервер удалит аккаунт, устройства, контакты, ваши каналы и загруженные вложения. С этого устройства будет удалён открытый локальный профиль. Собеседники сохранят историю сообщений. Резервные копии, экспортированные файлы и копии на других устройствах сохраняются.',
                'The server will remove your account, devices, contacts, channels and uploaded attachments. This device will erase the open local profile. Peers keep their message history. Backups, exported files and copies on other devices remain.',
              ),
            ),
            TextField(
              controller: password,
              obscureText: !visible,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: tr('Пароль аккаунта', 'Account password'),
                suffixIcon: IconButton(
                  tooltip: visible
                      ? tr('Скрыть пароль', 'Hide password')
                      : tr('Показать пароль', 'Show password'),
                  onPressed: working
                      ? null
                      : () => setState(() => visible = !visible),
                  icon: Icon(
                    visible
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            CheckboxListTile(
              value: accepted,
              title: Text(
                tr('Подтверждаю удаление', 'Confirm permanent removal'),
              ),
              onChanged: working
                  ? null
                  : (v) => setState(() => accepted = v ?? false),
            ),
            if (failed)
              Text(
                tr(
                  'Удаление не подтверждено. Проверьте пароль и подключение и повторите попытку.',
                  'Removal was not confirmed. Check the password and connection, then retry.',
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: working ? null : () => Navigator.pop(context, false),
          child: Text(tr('Отмена', 'Cancel')),
        ),
        FilledButton(
          onPressed: working || !accepted || password.text.isEmpty
              ? null
              : submit,
          child: Text(tr('Удалить аккаунт', 'Delete account')),
        ),
      ],
    ),
  );
}
