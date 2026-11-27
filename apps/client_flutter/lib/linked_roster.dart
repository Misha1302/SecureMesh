import 'package:material_ui/material_ui.dart';

typedef RosterTranslate = String Function(String, String);

/// Consent is distinct from a prior account enrollment or peer key pin.
Future<bool> confirmRosterChange(
  BuildContext context, {
  required String group,
  required String description,
  required RosterTranslate tr,
}) async {
  var checked = false;
  return await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, update) => AlertDialog(
            title: Text(
              tr('Состав приватного чата', 'Private chat membership'),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(group),
                  const SizedBox(height: 8),
                  SelectableText(description),
                  const SizedBox(height: 8),
                  Text(
                    tr(
                      'Новое устройство получит только будущие сообщения. Подтверждение аккаунта не является согласием для этого чата.',
                      'A new device receives future messages only. Account approval is not consent for this conversation.',
                    ),
                  ),
                  CheckboxListTile(
                    value: checked,
                    onChanged: (value) => update(() => checked = value == true),
                    title: Text(
                      tr(
                        'Я независимо проверил устройства и согласен изменить состав этого чата.',
                        'I independently verified the devices and consent to this conversation’s membership change.',
                      ),
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
                onPressed: checked ? () => Navigator.pop(ctx, true) : null,
                child: Text(tr('Подтвердить', 'Confirm')),
              ),
            ],
          ),
        ),
      ) ==
      true;
}
