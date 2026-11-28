import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'account_credentials.dart';
import 'account_setup.dart';
import 'local_client.dart';
import 'transport.dart';

Future<Map<String, String>> _deriveRecoveryCredential({
  required int version,
  required Uri endpoint,
  required String username,
  required String password,
}) async {
  await initializeNativeBridge();
  return accountCredentialFields(
    version: version,
    endpoint: endpoint,
    username: username,
    password: password,
  );
}

class AccountRecoveryPage extends StatefulWidget {
  const AccountRecoveryPage({
    super.key,
    required this.endpoint,
    required this.request,
    required this.russian,
    required this.initialUsername,
    this.derive = _deriveRecoveryCredential,
  });

  final Uri endpoint;
  final DeviceLoginRequest request;
  final bool russian;
  final String initialUsername;
  final CredentialDerivation derive;

  @override
  State<AccountRecoveryPage> createState() => _AccountRecoveryPageState();
}

class _AccountRecoveryPageState extends State<AccountRecoveryPage> {
  final identityForm = GlobalKey<FormState>();
  final codeForm = GlobalKey<FormState>();
  final nameField = GlobalKey<FormFieldState<String>>();
  late final username = TextEditingController(text: widget.initialUsername);
  final email = TextEditingController();
  final code = TextEditingController();
  final password = TextEditingController();
  final confirmation = TextEditingController();
  String? account, error;
  bool busy = false, requestedEmail = false, completed = false;

  String tr(String ru, String en) => widget.russian ? ru : en;

  @override
  void dispose() {
    for (final field in [username, email, code, password, confirmation]) {
      field.dispose();
    }
    super.dispose();
  }

  String get normalizedUsername =>
      username.text.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();

  Future<void> begin({required bool sendEmail}) async {
    if (busy) return;
    final valid = sendEmail
        ? identityForm.currentState!.validate()
        : nameField.currentState!.validate();
    if (!valid) return;
    final name = normalizedUsername;
    if (!sendEmail) {
      setState(() {
        account = name;
        error = null;
      });
      return;
    }
    await run(() async {
      await widget.request(
        '/v1/auth/recovery/request',
        data: {'email': email.text.trim()},
      );
      if (!mounted) return;
      setState(() {
        account = name;
        requestedEmail = true;
        email.clear();
      });
    });
  }

  Future<void> complete() async {
    if (busy || !codeForm.currentState!.validate()) return;
    final name = account!;
    final token = code.text.trim();
    final newPassword = password.text;
    await run(() async {
      final fields = await widget.derive(
        version: 2,
        endpoint: widget.endpoint,
        username: name,
        password: newPassword,
      );
      await widget.request(
        '/v2/auth/recovery/complete',
        data: {
          'username': name,
          'token': token,
          'credential': fields['credential']!,
        },
      );
      if (!mounted) return;
      setState(() {
        code.clear();
        password.clear();
        confirmation.clear();
        completed = true;
      });
    });
  }

  Future<void> run(Future<void> Function() request) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await request();
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        error = failure is ApiFailure && failure.code == 'INVALID_RECOVERY'
            ? tr(
                'Код или имя аккаунта не подошли. Проверьте их и при необходимости запросите новый код.',
                'The code or username did not match. Check them and request a new code if needed.',
              )
            : tr(
                'Не удалось подтвердить результат. Проверьте соединение. Если вы уже отправили код, попробуйте войти с новым паролем.',
                'Could not confirm the result. Check the connection. If you submitted the code, try signing in with the new password.',
              );
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String? validatePassword(String? value) {
    if (value == null ||
        value.characters.length < 16 ||
        value.characters.length > 256 ||
        utf8.encode(value).length > 4096 ||
        value.contains('\u0000')) {
      return tr(
        'Пароль должен содержать от 16 до 256 символов.',
        'Use 16–256 characters.',
      );
    }
    return null;
  }

  InputDecoration label(String text) => InputDecoration(
    labelText: text,
    border: const OutlineInputBorder(),
    errorMaxLines: 3,
  );

  Widget secret(
    TextEditingController controller,
    String title,
    String? Function(String?) validate, {
    Iterable<String>? autofill,
  }) => TextFormField(
    controller: controller,
    enabled: !busy,
    obscureText: true,
    autocorrect: false,
    enableSuggestions: false,
    autofillHints: autofill,
    decoration: label(title),
    validator: validate,
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(
        title: Text(tr('Восстановление аккаунта', 'Recover account')),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(widget.endpoint.origin),
                  const SizedBox(height: 16),
                  if (completed) ...[
                    Text(
                      tr(
                        'Пароль аккаунта изменён.',
                        'Account password changed.',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      tr(
                        'Чтобы открыть сохранённые чаты, разблокируйте прежний профиль его паролем хранилища. Затем выполните повторный вход с новым паролем аккаунта.',
                        'To open saved chats, unlock the original profile with its store passphrase. Then sign in again with the new account password.',
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: busy
                          ? null
                          : () => Navigator.of(context).pop(account),
                      child: Text(tr('Вернуться ко входу', 'Back to sign-in')),
                    ),
                  ] else ...[
                    Text(
                      tr(
                        'Код из почты меняет пароль аккаунта. Для чатов нужен исходный профиль и его пароль хранилища.',
                        'The email code changes your account password. Saved chats require the original profile and its store passphrase.',
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (account == null) identityFields() else codeFields(),
                  ],
                  if (busy) const LinearProgressIndicator(),
                  if (error != null)
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
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
  );

  Widget identityFields() => Form(
    key: identityForm,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          key: nameField,
          controller: username,
          enabled: !busy,
          autocorrect: false,
          decoration: label(tr('Имя аккаунта', 'Account username')),
          validator: (_) =>
              RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(normalizedUsername)
              ? null
              : tr(
                  'Используйте строчные a–z, цифры и знак подчёркивания.',
                  'Use lowercase a–z, digits and underscores.',
                ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: email,
          enabled: !busy,
          keyboardType: TextInputType.emailAddress,
          decoration: label(tr('Почта аккаунта', 'Account email')),
          validator: (value) =>
              value != null &&
                  value.length <= 254 &&
                  RegExp(r'^[^@\s<>]+@[^@\s<>]+$').hasMatch(value.trim())
              ? null
              : tr('Проверьте адрес почты.', 'Check the email address.'),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: busy ? null : () => begin(sendEmail: true),
          child: Text(tr('Отправить код на почту', 'Email me a recovery code')),
        ),
        TextButton(
          onPressed: busy ? null : () => begin(sendEmail: false),
          child: Text(tr('У меня уже есть код', 'I already have a code')),
        ),
      ],
    ),
  );

  Widget codeFields() => Form(
    key: codeForm,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('@$account'),
        if (requestedEmail)
          Text(
            tr(
              'Если почта подтверждена, на неё может прийти письмо с кодом. Проверьте также папку «Спам».',
              'Check your inbox and spam folder for a recovery code.',
            ),
          ),
        const SizedBox(height: 16),
        secret(
          code,
          tr('Код восстановления', 'Recovery code'),
          (value) => RegExp(r'^[a-f0-9]{64}$').hasMatch(value?.trim() ?? '')
              ? null
              : tr(
                  'Вставьте код из письма целиком.',
                  'Paste the full email code.',
                ),
          autofill: const [AutofillHints.oneTimeCode],
        ),
        const SizedBox(height: 16),
        secret(
          password,
          tr('Новый пароль аккаунта', 'New account password'),
          validatePassword,
          autofill: const [AutofillHints.newPassword],
        ),
        const SizedBox(height: 16),
        secret(
          confirmation,
          tr('Повторите новый пароль', 'Confirm new password'),
          (value) => value == password.text
              ? null
              : tr('Пароли не совпадают.', 'The passwords do not match.'),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: busy ? null : complete,
          child: Text(tr('Изменить пароль', 'Change account password')),
        ),
        TextButton(
          onPressed: busy
              ? null
              : () => setState(() {
                  account = null;
                  requestedEmail = false;
                  error = null;
                  code.clear();
                  password.clear();
                  confirmation.clear();
                }),
          child: Text(tr('Вернуться к запросу кода', 'Back to code request')),
        ),
      ],
    ),
  );
}
