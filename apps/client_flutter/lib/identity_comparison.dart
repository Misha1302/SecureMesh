import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:material_ui/material_ui.dart';

import 'identity_qr.dart';

typedef IdentityTranslation = String Function(String, String);

String? deviceFingerprint(String key) {
  try {
    final bytes = base64Decode(key);
    if (bytes.length != 32) return null;
    final hex = sha256.convert(bytes).toString().toUpperCase();
    return RegExp('.{4}').allMatches(hex).map((m) => m[0]!).join(' ');
  } on FormatException {
    return null;
  }
}

Future<bool> compareDeviceKey(
  BuildContext context,
  String ownKey,
  String peerKey,
  IdentityTranslation tr,
) async {
  final expected = deviceFingerprint(peerKey);
  final mine = deviceFingerprint(ownKey);
  var matches = false;
  String? feedback;
  return await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, update) => AlertDialog(
            title: Text(tr('Проверка личности', 'Compare device keys')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr(
                      'Попросите собеседника показать код своего устройства лично или прислать его через другой доверенный канал.',
                      'Ask your contact for their device code in person or through another trusted channel.',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    autocorrect: false,
                    enableSuggestions: false,
                    maxLines: 3,
                    minLines: 1,
                    textDirection: TextDirection.ltr,
                    decoration: InputDecoration(
                      labelText: tr('Код собеседника', 'Contact’s device code'),
                    ),
                    onChanged: (value) {
                      final code = value
                          .replaceAll(RegExp(r'\s'), '')
                          .toUpperCase();
                      update(() {
                        matches =
                            expected != null &&
                            (code == expected.replaceAll(' ', '') ||
                                deviceFingerprint(value.trim()) == expected);
                        feedback = null;
                      });
                    },
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.qr_code_scanner),
                    label: Text(tr('Сканировать QR-код', 'Scan QR code')),
                    onPressed: () async {
                      try {
                        final code = await scanIdentityCode(ctx, tr);
                        if (!ctx.mounted || code == null) return;
                        update(() {
                          matches =
                              expected != null &&
                              code == expected.replaceAll(' ', '');
                          feedback = matches
                              ? tr('Коды совпали', 'Codes match')
                              : tr(
                                  'Код принадлежит другому устройству',
                                  'This code belongs to another device',
                                );
                        });
                      } catch (_) {
                        if (ctx.mounted) {
                          update(() {
                            matches = false;
                            feedback = tr(
                              'Не удалось прочитать QR-код SecureMesh',
                              'Could not read a SecureMesh QR code',
                            );
                          });
                        }
                      }
                    },
                  ),
                  if (feedback != null)
                    Semantics(liveRegion: true, child: Text(feedback!)),
                  if (mine != null) ...[
                    const SizedBox(height: 20),
                    Text(tr('Ваш код для сверки', 'Your device code')),
                    SelectableText(mine, textDirection: TextDirection.ltr),
                    TextButton.icon(
                      icon: const Icon(Icons.qr_code),
                      label: Text(tr('Показать мой QR-код', 'Show my QR code')),
                      onPressed: () => showOwnDeviceCode(ctx, mine, tr),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr('Отмена', 'Cancel')),
              ),
              FilledButton(
                onPressed: matches ? () => Navigator.pop(ctx, true) : null,
                child: Text(tr('Подтвердить', 'Confirm')),
              ),
            ],
          ),
        ),
      ) ??
      false;
}

Future<void> showOwnDeviceCode(
  BuildContext context,
  String code,
  IdentityTranslation tr,
) => showDialog<void>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: Text(tr('Код этого устройства', 'This device’s code')),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: CustomPaint(painter: DeviceQr(code)),
          ),
          const SizedBox(height: 12),
          SelectableText(code, textDirection: TextDirection.ltr),
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
);
