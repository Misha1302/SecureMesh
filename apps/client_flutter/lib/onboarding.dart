import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'http_api.dart';
import 'local_client.dart';
import 'src/rust/api.dart';
import 'transport.dart';

class AccountOnboarding extends StatefulWidget {
  const AccountOnboarding({
    super.key,
    required this.onReady,
    this.russian = true,
  });
  final Future<void> Function(String path, String passphrase) onReady;
  final bool russian;
  @override
  State<AccountOnboarding> createState() => _AccountOnboardingState();
}

class _AccountOnboardingState extends State<AccountOnboarding> {
  final endpoint = TextEditingController(text: 'https://127.0.0.1:5088');
  final username = TextEditingController();
  final email = TextEditingController();
  final password = TextEditingController();
  final localPassword = TextEditingController();
  final verification = TextEditingController();
  final form = GlobalKey<FormState>();
  HttpClient? http;
  NativeClient? store;
  String? storePath, identity, error;
  bool busy = false, ru = true, verifiedRegistrationHere = false;
  bool accountAuthenticated = false;
  int step = 0; // register, email verification, login
  String tr(String a, String b) => ru ? a : b;

  @override
  void initState() {
    super.initState();
    ru = widget.russian;
  }

  @override
  void dispose() {
    for (final c in [
      endpoint,
      username,
      email,
      password,
      localPassword,
      verification,
    ]) {
      c.dispose();
    }
    http?.close(force: true);
    store?.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> crypto(
    String op, [
    Map<String, dynamic> args = const {},
  ]) async =>
      jsonDecode(await store!.execute(request: jsonEncode({'op': op, ...args})))
          as Map<String, dynamic>;

  Future<void> submit() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final base = Uri.parse(endpoint.text.trim());
      if (base.scheme != 'https' ||
          base.host.isEmpty ||
          base.userInfo.isNotEmpty) {
        throw ApiFailure(400, 'TLS_REQUIRED');
      }
      http ??= nativeHttpClient();
      if (step == 0) {
        await meshHttp(
          http!,
          base,
          '/v1/auth/register',
          data: {
            'username': username.text.trim(),
            'email': email.text.trim(),
            'password': password.text,
          },
        );
        if (mounted) setState(() => step = 1);
      } else if (step == 1) {
        await meshHttp(
          http!,
          base,
          '/v1/auth/verify-email',
          data: {'token': verification.text.trim()},
        );
        verification.clear();
        verifiedRegistrationHere = true;
        if (mounted) setState(() => step = 2);
      } else {
        await initializeNativeBridge();
        if (store == null) {
          final create = identity == null;
          if (create) {
            final location =
                Platform.environment['SECUREMESH_PROFILE_DIRECTORY'];
            final directory = location == null
                ? await getApplicationSupportDirectory()
                : Directory(location);
            await directory.create(recursive: true);
            identity = newUuid();
            storePath = '${directory.path}/$identity.db';
          }
          store = await NativeClient.open(
            path: storePath!,
            passphrase: localPassword.text,
          );
          if (create) await crypto('init', {'identity': identity});
        }
        final me = await crypto('identity');
        final challenge = await meshHttp(
          http!,
          base,
          '/v1/auth/challenge',
          data: {'username': username.text.trim(), 'deviceId': identity},
        ) as Map;
        final proof = await crypto('sign', {'payload': challenge['payload']});
        final session = await meshHttp(
          http!,
          base,
          '/v1/auth/login',
          data: {
            'username': username.text.trim(),
            'password': password.text,
            'deviceId': identity,
            'publicKey': me['public_key'],
            'challengeId': challenge['challengeId'],
            'signature': proof['signature'],
          },
        ) as Map<String, dynamic>;
        accountAuthenticated = true;
        final account = await meshHttp(
          http!,
          base,
          '/v1/users/me',
          token: session['accessToken'] as String,
        ) as Map;
        await crypto('profile_put', {
          'profile': {
            'endpoint': base.origin,
            'username': username.text.trim(),
            'userId': account['userId'],
            ...session,
            'requiresEnrollment':
                !verifiedRegistrationHere ||
                session['trustState'] == 'DEVICE_PENDING_TRUST',
            'enrollmentVerified':
                verifiedRegistrationHere &&
                session['trustState'] == 'DEVICE_TRUSTED',
          },
        });
        store!.dispose();
        store = null;
        final passphrase = localPassword.text;
        await widget.onReady(storePath!, passphrase);
        password.clear();
        localPassword.clear();
        if (mounted) Navigator.of(context).pop();
      }
    } catch (failure) {
      if (failure is ApiFailure &&
          const {400, 401, 403}.contains(failure.status) &&
          !accountAuthenticated) {
        // A conclusive rejection did not enroll this device. Keep the unused
        // encrypted file, but allow corrected credentials to create a new draft.
        store?.dispose();
        store = null;
        identity = null;
        storePath = null;
      }
      if (mounted) {
        setState(() {
          error = failure is ApiFailure && failure.status == 401
              ? tr(
                  'Не удалось войти. Проверьте имя, пароль и подтверждение почты.',
                  'Could not sign in. Check your username, password and email verification.',
                )
              : failure is ApiFailure && failure.code == 'INVALID_TOKEN'
              ? tr(
                  'Код недействителен или уже использован. Проверьте письмо.',
                  'The code is invalid or already used. Check your email.',
                )
              : tr(
                  'Действие не завершено. Проверьте соединение и данные, затем повторите.',
                  'The action did not complete. Check the connection and your details, then retry.',
                );
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget field(
    TextEditingController controller,
    String label, {
    bool secret = false,
    int min = 1,
    int max = 256,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      controller: controller,
      enabled:
          !busy &&
          !(store != null &&
              [endpoint, username, localPassword].contains(controller)),
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: !secret,
      keyboardType: keyboard,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      validator: (v) => v == null || v.length < min || v.length > max
          ? tr(
              'Введите от $min до $max символов.',
              'Enter $min–$max characters.',
            )
          : null,
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(
        title: Text(tr('Аккаунт', 'Account')),
        actions: [
          TextButton(
            onPressed: busy ? null : () => setState(() => ru = !ru),
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
                        step == 0
                            ? tr('Создать аккаунт', 'Create an account')
                            : step == 1
                            ? tr('Подтвердите почту', 'Verify your email')
                            : tr(
                                'Войти на этом устройстве',
                                'Sign in on this device',
                              ),
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        step == 1
                            ? tr(
                                'Введите код из письма. В локальной версии письмо доступно в Mailpit.',
                                'Enter the code from your email. Local development mail is available in Mailpit.',
                              )
                            : step == 2
                            ? tr(
                                'Устройство создаст свои ключи. Для подключения нужно подтверждение. Перенос старой истории и восстановление в этой альфе ещё недоступны.',
                                'This device creates its own keys and needs approval. History transfer and recovery are not available in this alpha yet.',
                              )
                            : tr(
                                'Телефон не нужен. Приватные ключи остаются на ваших устройствах.',
                                'No phone number is required. Private keys stay on your devices.',
                              ),
                      ),
                      const SizedBox(height: 24),
                      field(
                        endpoint,
                        tr('Сервер HTTPS', 'HTTPS server'),
                        keyboard: TextInputType.url,
                      ),
                      if (step != 1)
                        field(
                          username,
                          tr('Имя пользователя', 'Username'),
                          min: 3,
                          max: 32,
                        ),
                      if (step == 0)
                        field(
                          email,
                          tr('Электронная почта', 'Email'),
                          max: 254,
                          keyboard: TextInputType.emailAddress,
                        ),
                      if (step != 1)
                        field(
                          password,
                          tr('Пароль аккаунта', 'Account password'),
                          secret: true,
                          min: 12,
                        ),
                      if (step == 1)
                        field(
                          verification,
                          tr('Код из письма', 'Email verification code'),
                          secret: true,
                          max: 128,
                        ),
                      if (step == 2) ...[
                        field(
                          localPassword,
                          tr(
                            'Пароль локального хранилища',
                            'Local store passphrase',
                          ),
                          secret: true,
                          min: 16,
                        ),
                        Text(
                          tr(
                            'Этот пароль не отправляется серверу. Сохраните его: он нужен для открытия ключей на этом устройстве.',
                            'This passphrase is never sent to the server. Keep it: you need it to unlock keys on this device.',
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
                      if (error != null)
                        Semantics(
                          liveRegion: true,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: Text(
                              error!,
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
                                : step == 0
                                ? tr('Создать аккаунт', 'Create account')
                                : step == 1
                                ? tr('Подтвердить почту', 'Verify email')
                                : tr('Войти', 'Sign in'),
                          ),
                        ),
                      ),
                      if (step != 1)
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => setState(() {
                                  step = step == 0 ? 2 : 0;
                                  error = null;
                                }),
                          child: Text(
                            step == 0
                                ? tr('Уже есть аккаунт', 'I have an account')
                                : tr('Создать аккаунт', 'Create account'),
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
