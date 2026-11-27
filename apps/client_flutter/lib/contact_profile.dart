import 'package:material_ui/material_ui.dart';

import 'identity_comparison.dart';

enum ContactKeyState { unverified, verified, changed }

Future<bool> showContactProfile(
  BuildContext context, {
  required Widget avatar,
  required String displayName,
  required String username,
  required ContactKeyState keyState,
  required String? verifiedFingerprint,
  Widget? profileText,
  required IdentityTranslation tr,
  required Future<void> Function(BuildContext) openMedia,
}) async {
  final verified = keyState == ContactKeyState.verified;
  final changed = keyState == ContactKeyState.changed;
  return await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('Профиль собеседника', 'Contact profile')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ExcludeSemantics(child: avatar),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            displayName,
                            style: Theme.of(ctx).textTheme.titleMedium,
                          ),
                          SelectableText(
                            '@$username',
                            textDirection: TextDirection.ltr,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (verified && profileText != null) profileText,
                if (verified)
                  TextButton.icon(
                    onPressed: () => openMedia(ctx),
                    icon: const Icon(Icons.perm_media_outlined),
                    label: Text(tr('Медиа диалога', 'Shared media')),
                  ),
                const Divider(height: 32),
                Text(
                  tr('Безопасность', 'Security'),
                  style: Theme.of(ctx).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                Text(switch (keyState) {
                  ContactKeyState.verified => tr(
                    'Ключ устройства проверен',
                    'Device key verified',
                  ),
                  ContactKeyState.unverified => tr(
                    'Требуется проверка личности',
                    'Identity verification required',
                  ),
                  ContactKeyState.changed => tr(
                    'Ключ или устройство изменились. Чат заблокирован.',
                    'Key or device changed. This chat is blocked.',
                  ),
                }),
                if (verified && verifiedFingerprint != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    tr('Код устройства собеседника', 'Contact’s device code'),
                  ),
                  SelectableText(
                    verifiedFingerprint,
                    textDirection: TextDirection.ltr,
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Закрыть', 'Close')),
            ),
            if (!changed)
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(
                  verified
                      ? tr('Сверить ещё раз', 'Compare again')
                      : tr('Проверить личность', 'Verify identity'),
                ),
              ),
          ],
        ),
      ) ??
      false;
}
