import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'linux_profile_keyring.dart';

const profileBiometrics = MethodChannel('securemesh/profile_biometrics');

enum BiometricAction { enable, unlock, forget }

class ProfileBiometricActions extends StatefulWidget {
  const ProfileBiometricActions({
    super.key,
    required this.path,
    required this.disabled,
    this.linuxKeyring = false,
    required this.russian,
    required this.perform,
  });

  final TextEditingController path;
  final bool disabled, russian, linuxKeyring;
  final Future<void> Function(BiometricAction) perform;

  @override
  State<ProfileBiometricActions> createState() =>
      _ProfileBiometricActionsState();
}

class _ProfileBiometricActionsState extends State<ProfileBiometricActions> {
  Timer? debounce;
  int request = 0;
  String status = 'unavailable';

  @override
  void initState() {
    super.initState();
    widget.path.addListener(reload);
    reload();
  }

  @override
  void dispose() {
    debounce?.cancel();
    widget.path.removeListener(reload);
    super.dispose();
  }

  void reload() {
    final epoch = ++request;
    final path = widget.path.text.trim();
    debounce?.cancel();
    if (status != 'unavailable') setState(() => status = 'unavailable');
    if (path.isEmpty) return;
    debounce = Timer(const Duration(milliseconds: 200), () async {
      String? value;
      try {
        value = widget.linuxKeyring
            ? await LinuxProfileKeyring.status(path)
            : await profileBiometrics.invokeMethod<String>('status', {
                'path': path,
              });
      } on PlatformException {
        value = null;
      } on MissingPluginException {
        value = null;
      }
      if (mounted && epoch == request) {
        setState(() => status = value ?? 'unavailable');
      }
    });
  }

  Future<void> run(BiometricAction action) async {
    await widget.perform(action);
    if (mounted) reload();
  }

  @override
  Widget build(BuildContext context) {
    final recovery = status == 'recovery';
    if (!recovery && status != 'enrolled' && status != 'available') {
      return const SizedBox.shrink();
    }
    final enrolled = status == 'enrolled';
    return Column(
      children: [
        if (widget.linuxKeyring && !enrolled)
          Text(
            widget.russian
                ? 'Пароль профиля будет сохранён в системной связке ключей. В открытом сеансе рабочего стола он может быть доступен другим приложениям.'
                : 'Your profile passphrase will be saved in the system keyring. Other apps in your unlocked desktop session may have access.',
          ),
        if (recovery)
          Text(
            widget.russian
                ? 'Биометрический вход недоступен. Откройте профиль паролем хранилища.'
                : 'Biometric unlock is unavailable. Open your profile with its store passphrase.',
          )
        else
          OutlinedButton.icon(
            onPressed: widget.disabled
                ? null
                : () => run(
                    enrolled ? BiometricAction.unlock : BiometricAction.enable,
                  ),
            icon: Icon(widget.linuxKeyring ? Icons.key : Icons.fingerprint),
            label: Text(
              widget.linuxKeyring
                  ? (enrolled
                        ? (widget.russian
                              ? 'Открыть связкой ключей'
                              : 'Unlock with keyring')
                        : (widget.russian
                              ? 'Сохранить пароль в связке ключей'
                              : 'Save passphrase in keyring'))
                  : enrolled
                  ? (widget.russian
                        ? 'Открыть с биометрией'
                        : 'Unlock with biometrics')
                  : (widget.russian
                        ? 'Включить биометрию для этого профиля'
                        : 'Enable biometrics for this profile'),
            ),
          ),
        if (enrolled || recovery)
          TextButton(
            onPressed: widget.disabled
                ? null
                : () => run(BiometricAction.forget),
            child: Text(
              widget.linuxKeyring
                  ? (widget.russian
                        ? 'Удалить пароль из связки ключей'
                        : 'Remove passphrase from keyring')
                  : widget.russian
                  ? 'Отключить вход с биометрией'
                  : 'Forget biometric unlock',
            ),
          ),
      ],
    );
  }
}
