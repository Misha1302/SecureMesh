import 'package:material_ui/material_ui.dart';

class SecurityEmailTile extends StatefulWidget {
  const SecurityEmailTile({
    super.key,
    required this.russian,
    required this.request,
  });

  final bool russian;
  final Future<dynamic> Function(
    String route, {
    Map<String, dynamic>? data,
    String? method,
  })
  request;

  @override
  State<SecurityEmailTile> createState() => _SecurityEmailTileState();
}

class _SecurityEmailTileState extends State<SecurityEmailTile> {
  bool? enabled;
  bool busy = true;
  bool failed = false;

  @override
  void initState() {
    super.initState();
    update();
  }

  Future<void> update([bool? choice]) async {
    setState(() {
      busy = true;
      failed = false;
    });
    try {
      const path = '/v1/users/me/security-email';
      final result = choice == null
          ? await widget.request(path)
          : await widget.request(
              path,
              method: 'PUT',
              data: {'enabled': choice},
            );
      if (result is! Map ||
          result['enabled'] is! bool ||
          (choice != null && result['enabled'] != choice)) {
        throw const FormatException('INVALID_SECURITY_EMAIL_PREFERENCE');
      }
      if (mounted) setState(() => enabled = result['enabled'] as bool);
    } catch (_) {
      if (mounted) {
        setState(() {
          enabled = null;
          failed = true;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = Text(
      widget.russian ? 'Письма о безопасности' : 'Security emails',
    );
    if (enabled == null) {
      return ListTile(
        title: title,
        subtitle: Text(
          failed
              ? (widget.russian
                    ? 'Не удалось проверить настройку.'
                    : 'Could not check this setting.')
              : (widget.russian ? 'Загрузка…' : 'Loading…'),
        ),
        trailing: failed
            ? TextButton(
                onPressed: busy ? null : update,
                child: Text(widget.russian ? 'Повторить' : 'Retry'),
              )
            : null,
      );
    }
    return SwitchListTile(
      title: title,
      value: enabled!,
      onChanged: busy ? null : update,
      subtitle: Text(
        widget.russian
            ? 'На подтверждённую почту при подключении доверенного устройства или повторном использовании ключа сеанса.'
            : 'Email me when a device becomes trusted or a rotated session token is reused.',
      ),
    );
  }
}
