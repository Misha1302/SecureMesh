import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

const profileBiometrics = MethodChannel('securemesh/profile_biometrics');

enum BiometricAction { enable, unlock, forget }

class ProfileBiometricActions extends StatefulWidget {
  const ProfileBiometricActions({
    super.key,
    required this.path,
    required this.disabled,
    required this.russian,
    required this.perform,
  });

  final TextEditingController path;
  final bool disabled, russian;
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
        value = await profileBiometrics.invokeMethod<String>('status', {
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
    if (status != 'enrolled' && status != 'available') {
      return const SizedBox.shrink();
    }
    final enrolled = status == 'enrolled';
    return Column(
      children: [
        OutlinedButton.icon(
          onPressed: widget.disabled
              ? null
              : () => run(
                  enrolled ? BiometricAction.unlock : BiometricAction.enable,
                ),
          icon: const Icon(Icons.fingerprint),
          label: Text(
            enrolled
                ? (widget.russian
                      ? 'Открыть с биометрией'
                      : 'Unlock with biometrics')
                : (widget.russian
                      ? 'Включить биометрию для этого профиля'
                      : 'Enable biometrics for this profile'),
          ),
        ),
        if (enrolled)
          TextButton(
            onPressed: widget.disabled
                ? null
                : () => run(BiometricAction.forget),
            child: Text(
              widget.russian
                  ? 'Отключить вход с биометрией'
                  : 'Forget biometric unlock',
            ),
          ),
      ],
    );
  }
}
