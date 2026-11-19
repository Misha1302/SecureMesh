import 'package:material_ui/material_ui.dart';

import 'transport.dart';

enum _SignInError { credentials, device, challenge, rate, connection }

class ProfileReauthentication extends StatefulWidget {
  const ProfileReauthentication({
    super.key,
    required this.onSignIn,
    this.username,
    this.russian = true,
  });
  final String? username;
  final bool russian;
  final Future<void> Function(String username, String password) onSignIn;

  @override
  State<ProfileReauthentication> createState() =>
      _ProfileReauthenticationState();
}

class _ProfileReauthenticationState extends State<ProfileReauthentication> {
  late final username = TextEditingController(text: widget.username ?? '');
  final password = TextEditingController();
  final form = GlobalKey<FormState>();
  late bool ru = widget.russian;
  bool busy = false, submitted = false;
  _SignInError? error;
  String tr(String a, String b) => ru ? a : b;

  @override
  void dispose() {
    username.dispose();
    password.dispose();
    super.dispose();
  }

  String get errorText => switch (error) {
    _SignInError.credentials => tr(
      'Не удалось войти. Проверьте пароль аккаунта и имя пользователя.',
      'Could not sign in. Check your account password and username.',
    ),
    _SignInError.device => tr(
      'Сервер не разрешил вход с ключами этого устройства. Проверьте аккаунт или используйте доверенное устройство.',
      'The server denied sign-in with this device’s keys. Check the account or use a trusted device.',
    ),
    _SignInError.challenge => tr(
      'Серверный запрос не соответствует этому профилю. Вход остановлен.',
      'The server challenge does not match this profile. Sign-in was stopped.',
    ),
    _SignInError.rate => tr(
      'Слишком много попыток. Повторите позже.',
      'Too many attempts. Try again later.',
    ),
    _ => tr(
      'Не удалось завершить вход. Проверьте соединение и повторите. Ключи и очередь сохранены.',
      'Could not finish signing in. Check the connection and retry. Your keys and queue are preserved.',
    ),
  };

  Future<void> submit() async {
    if (busy) return;
    submitted = true;
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.onSignIn(username.text.trim(), password.text);
      password.clear();
      if (mounted) Navigator.of(context).pop(true);
    } catch (failure) {
      if (mounted) {
        setState(() {
          error =
              failure is ApiFailure &&
                  failure.code == 'DEVICE_CHALLENGE_MISMATCH'
              ? _SignInError.challenge
              : failure is ApiFailure &&
                    (failure.status == 403 || failure.code == 'DEVICE_REVOKED')
              ? _SignInError.device
              : failure is ApiFailure && failure.status == 401
              ? _SignInError.credentials
              : failure is ApiFailure && failure.status == 429
              ? _SignInError.rate
              : _SignInError.connection;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(
        title: Text(tr('Повторный вход', 'Sign in again')),
        actions: [
          TextButton(
            onPressed: busy
                ? null
                : () {
                    setState(() => ru = !ru);
                    if (submitted) form.currentState!.validate();
                  },
            child: const Text('RU / EN'),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: form,
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        tr('Войти в этот профиль', 'Sign in to this profile'),
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        tr(
                          'Используются ключи открытого профиля. Локальная история и очередь сохранятся.',
                          'This uses the open profile’s keys. Your local history and queue will be preserved.',
                        ),
                      ),
                      const SizedBox(height: 24),
                      TextFormField(
                        controller: username,
                        enabled: !busy,
                        readOnly: widget.username != null,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: tr('Имя пользователя', 'Username'),
                          errorMaxLines: 3,
                          border: const OutlineInputBorder(),
                        ),
                        validator: (value) =>
                            value != null &&
                                RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(value)
                            ? null
                            : tr(
                                'Введите имя аккаунта: строчные a–z, цифры и подчёркивание.',
                                'Enter your account username: lowercase a–z, digits and underscores.',
                              ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: password,
                        enabled: !busy,
                        obscureText: true,
                        enableSuggestions: false,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: tr('Пароль аккаунта', 'Account password'),
                          errorMaxLines: 3,
                          border: const OutlineInputBorder(),
                        ),
                        onFieldSubmitted: (_) => submit(),
                        validator: (value) =>
                            value != null &&
                                value.length >= 12 &&
                                value.length <= 256
                            ? null
                            : tr(
                                'Введите от 12 до 256 символов.',
                                'Enter 12–256 characters.',
                              ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        tr(
                          'Пароль хранилища здесь не нужен: профиль уже открыт.',
                          'The store passphrase is not needed here: this profile is already open.',
                        ),
                      ),
                      const SizedBox(height: 20),
                      if (error != null)
                        Semantics(
                          liveRegion: true,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: Text(
                              errorText,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        ),
                      FilledButton(
                        onPressed: busy ? null : submit,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            busy
                                ? tr('Выполняем…', 'Working…')
                                : tr('Войти', 'Sign in'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
