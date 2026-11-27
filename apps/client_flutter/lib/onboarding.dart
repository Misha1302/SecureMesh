import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'account_setup.dart';
import 'account_credentials.dart';
import 'display_name.dart';

import 'dart:convert';

import 'http_api.dart';
import 'local_client.dart';
import 'profile_files.dart';
import 'src/rust/api.dart';
import 'transport.dart';

Uri? httpsServerOrigin(String text) {
  final value = text.trim();
  if (value.isEmpty || value.contains(RegExp(r'[@\s\\]'))) return null;
  try {
    final uri = Uri.parse(value);
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.port < 1 ||
        uri.port > 65535) {
      return null;
    }
    return Uri.parse(uri.origin);
  } on FormatException {
    return null;
  }
}

class AccountOnboarding extends StatefulWidget {
  const AccountOnboarding({
    super.key,
    required this.onReady,
    this.russian = true,
    this.signIn = false,
    this.defaultServer = const String.fromEnvironment('SECUREMESH_API_ORIGIN'),
    this.resumePath,
    this.resumePassphrase,
  }) : assert((resumePath == null) == (resumePassphrase == null));
  final Future<void> Function(String path, String passphrase) onReady;
  final bool russian, signIn;
  final String defaultServer;
  final String? resumePath, resumePassphrase;
  @override
  State<AccountOnboarding> createState() => _AccountOnboardingState();
}

class _AccountOnboardingState extends State<AccountOnboarding> {
  final endpoint = TextEditingController();
  bool editingServer = false;
  final username = TextEditingController();
  final displayName = TextEditingController();
  bool legacy = false, remembered = false;
  final revealed = <TextEditingController>{};
  final email = TextEditingController();
  final password = TextEditingController();
  final localPassword = TextEditingController();
  final verification = TextEditingController();
  final form = GlobalKey<FormState>();
  HttpClient? http;
  NativeClient? store;
  AccountSetup? setup;
  Map<String, dynamic>? draft;
  String? storePath, identity;
  ({String ru, String en})? error;
  bool busy = false, ru = true, verifiedRegistrationHere = false;
  bool resuming = false, profileComplete = false;
  bool get needsAccountPassword =>
      !(verifiedRegistrationHere && !legacy) &&
      !(resuming && !legacy) &&
      !profileComplete &&
      draft?['session'] == null;
  int step = 0; // register, email verification, login
  String tr(String a, String b) => ru ? a : b;

  @override
  void initState() {
    super.initState();
    ru = widget.russian;
    final configured =
        Platform.environment['SECUREMESH_API_ORIGIN'] ?? widget.defaultServer;
    endpoint.text = httpsServerOrigin(configured)?.origin ?? '';
    editingServer = endpoint.text.isEmpty;
    if (widget.signIn) step = 2;
    if (widget.resumePath != null) {
      busy = true;
      resuming = true;
      step = 2;
      unawaited(loadResume());
    }
  }

  @override
  void dispose() {
    for (final c in [
      endpoint,
      username,
      displayName,
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

  Future<void> loadResume() async {
    try {
      await initializeNativeBridge();
      storePath = widget.resumePath!;
      localPassword.text = widget.resumePassphrase!;
      if (!File(storePath!).existsSync()) throw StateError('DRAFT_MISSING');
      final opened = await NativeClient.open(
        path: storePath!,
        passphrase: localPassword.text,
      );
      if (!mounted) {
        opened.dispose();
        return;
      }
      store = opened;
      http ??= nativeHttpClient();
      setup = AccountSetup(store: opened, http: http!);
      final state = await setup!.state();
      draft = state['draft'] as Map<String, dynamic>?;
      if (draft == null) throw StateError('DRAFT_MISSING');
      final version = draft!['credentialVersion'] ?? 1;
      if (version != 1 && version != 2) {
        throw StateError('Unsupported credential version');
      }
      legacy = version == 1;
      if (!legacy) password.text = widget.resumePassphrase!;
      endpoint.text = draft!['endpoint'] as String;
      username.text = draft!['username'] as String;
      identity = draft!['deviceId'] as String;
      verifiedRegistrationHere = draft!['registeredHere'] == true;
    } catch (_) {
      store?.dispose();
      store = null;
      setup = null;
      error = (
        ru: 'Не удалось открыть незавершённый вход. Вернитесь назад и откройте исходный файл с его паролем хранилища.',
        en: 'Could not open the interrupted sign-in. Go back and unlock the original file with its store passphrase.',
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> submit() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final base = httpsServerOrigin(endpoint.text);
      if (base == null) {
        throw ApiFailure(400, 'TLS_REQUIRED');
      }
      http ??= nativeHttpClient();
      if (step == 0) {
        await initializeNativeBridge();
        await meshHttp(
          http!,
          base,
          '/v2/auth/register',
          data: {
            'username': username.text.trim(),
            'email': email.text.trim(),
            'displayName': displayName.text.trim(),
            ...await accountCredentialFields(
              version: 2,
              endpoint: base,
              username: username.text.trim(),
              password: password.text,
            ),
          },
        );
        if (mounted) {
          setState(() {
            step = 1;
            editingServer = false;
          });
        }
        return;
      }
      if (step == 1) {
        await meshHttp(
          http!,
          base,
          '/v1/auth/verify-email',
          data: {'token': verification.text.trim()},
        );
        verification.clear();
        verifiedRegistrationHere = true;
        if (mounted) setState(() => step = 2);
      }
      final localKey = legacy ? localPassword.text : password.text;
      await initializeNativeBridge();
      if (!profileComplete && setup == null) {
        if (identity == null) {
          final directory = await localProfileDirectory();
          await directory.create(recursive: true);
          identity = newUuid();
          storePath = '${directory.path}/$identity.db';
        }
        store = await NativeClient.open(path: storePath!, passphrase: localKey);
        http ??= nativeHttpClient();
        final prepared = AccountSetup(store: store!, http: http!);
        try {
          await prepared.prepare(
            device: identity!,
            endpoint: base,
            username: username.text.trim(),
            registeredHere: verifiedRegistrationHere,
            credentialVersion: legacy ? 1 : 2,
          );
        } catch (_) {
          // No login was sent. A rejected initializer must not trap the
          // corrected form on an uninitialized database connection.
          store?.dispose();
          store = null;
          setup = null;
          identity = null;
          storePath = null;
          rethrow;
        }
        setup = prepared;
        draft = (await setup!.state())['draft'] as Map<String, dynamic>;
      }
      if (!profileComplete) await setup!.finish(password: password.text);
      profileComplete = true;
      store?.dispose();
      store = null;
      setup = null;
      await widget.onReady(storePath!, localKey);
      password.clear();
      localPassword.clear();
      if (mounted) Navigator.of(context).pop();
    } catch (failure) {
      if (setup != null) {
        try {
          final state = await setup!.state();
          draft = state['draft'] as Map<String, dynamic>?;
          if (failure is ApiFailure &&
              const {400, 401, 403}.contains(failure.status) &&
              draft?['loginUncertain'] == false &&
              draft?['session'] == null) {
            // Only a conclusive rejection with no earlier ambiguous login may
            // release the unused draft. Never discard a potentially live key.
            store?.dispose();
            store = null;
            setup = null;
            identity = null;
            storePath = null;
            draft = null;
            resuming = false;
          }
        } catch (_) {
          // An unreadable journal keeps its identity/path; it cannot authorize
          // a fresh device as an implicit recovery action.
        }
      }
      if (mounted) {
        setState(() {
          error =
              failure is ApiFailure &&
                  failure.code == 'DEVICE_CHALLENGE_MISMATCH'
              ? (
                  ru: 'Сервер вернул неподходящий запрос подписи. Проверьте адрес сервера; вход не выполнен.',
                  en: 'The server returned an invalid signing challenge. Check the server address; sign-in was stopped.',
                )
              : failure is ApiFailure &&
                    failure.code == 'ONBOARDING_SESSION_EXPIRED'
              ? (
                  ru: 'Сеанс истёк. Введите пароль аккаунта, чтобы продолжить с теми же ключами устройства.',
                  en: 'The session expired. Enter your account password to continue with the same device keys.',
                )
              : failure is ApiFailure && failure.status == 401
              ? (
                  ru: 'Не удалось войти. Проверьте имя, пароль и подтверждение почты.',
                  en: 'Could not sign in. Check your username, password and email verification.',
                )
              : failure is ApiFailure && failure.code == 'INVALID_TOKEN'
              ? (
                  ru: 'Код недействителен или уже использован. Проверьте письмо.',
                  en: 'The code is invalid or already used. Check your email.',
                )
              : (
                  ru: 'Действие не завершено. Проверьте соединение и данные, затем повторите.',
                  en: 'The action did not complete. Check the connection and your details, then retry.',
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
    String? help,
    String? example,
    bool secret = false,
    int min = 1,
    int max = 256,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      controller: controller,
      enabled: !busy,
      readOnly:
          (verifiedRegistrationHere && controller == username) ||
          (draft != null &&
              ([endpoint, username, localPassword].contains(controller) ||
                  (!legacy && controller == password))),
      obscureText: secret && !revealed.contains(controller),
      autocorrect: false,
      enableSuggestions: !secret,
      autofillHints: controller == password
          ? [step == 0 ? AutofillHints.newPassword : AutofillHints.password]
          : controller == username
          ? const [AutofillHints.username]
          : null,
      keyboardType: keyboard,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: secret
            ? IconButton(
                tooltip: revealed.contains(controller)
                    ? tr('Скрыть', 'Hide')
                    : tr('Показать', 'Show'),
                icon: Icon(
                  revealed.contains(controller)
                      ? Icons.visibility_off
                      : Icons.visibility,
                ),
                onPressed: () => setState(() {
                  if (!revealed.remove(controller)) revealed.add(controller);
                }),
              )
            : null,
        helperText: help,
        helperMaxLines: 8,
        errorMaxLines: 5,
        hintText: example,
        border: const OutlineInputBorder(),
      ),
      validator: (v) {
        final length = legacy && controller == password
            ? v?.length
            : v?.characters.length;
        if (v == null ||
            length == null ||
            length < min ||
            length > max ||
            (controller == password &&
                !legacy &&
                (utf8.encode(v).length > 4096 || v.contains('\u0000')))) {
          return tr(
            'Введите от $min до $max символов.',
            'Enter $min–$max characters.',
          );
        }
        if (controller == displayName && peerDisplayName(v) == null) {
          return tr(
            'Введите имя в одну строку.',
            'Enter your name on one line.',
          );
        }
        if (controller == localPassword && v == password.text) {
          return tr(
            'Выберите отдельный пароль хранилища.',
            'Choose a separate local passphrase.',
          );
        }
        if (controller == endpoint) {
          if (httpsServerOrigin(v) == null) {
            return tr(
              'Укажите HTTPS-адрес сервера без пути, например https://chat.example.org.',
              'Enter the HTTPS server address without a path, for example https://chat.example.org.',
            );
          }
        }
        if (controller == email &&
            !RegExp(r'^[^@\s<>]+@[^@\s<>]+$').hasMatch(v.trim())) {
          return tr(
            'Введите адрес почты, например name@example.org.',
            'Enter an email address, such as name@example.org.',
          );
        }
        if (controller == username &&
            !RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(v)) {
          return tr(
            'Используйте строчные a–z, цифры и знак подчёркивания.',
            'Use lowercase a–z, digits and underscores.',
          );
        }
        return null;
      },
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
                            : resuming || draft != null
                            ? tr('Продолжить вход', 'Continue sign-in')
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
                                'Проверьте почту ${email.text.trim()} и папку «Спам». Код действует 30 минут.',
                                'Check ${email.text.trim()} and your spam folder. The code is valid for 30 minutes.',
                              )
                            : step == 2
                            ? resuming || draft != null
                                  ? tr(
                                      'Ключи этого устройства сохранены. Для завершения входа нужно соединение с сервером. Старая история с других устройств не переносится.',
                                      'This device’s keys are saved. Connect to the server to finish signing in. History from other devices is not transferred.',
                                    )
                                  : tr(
                                      'Устройство создаст свои ключи. Для подключения нужно подтверждение. Перенос старой истории и восстановление в этой альфе ещё недоступны.',
                                      'This device creates its own keys and needs approval. History transfer and recovery are not available in this alpha yet.',
                                    )
                            : tr(
                                'Телефон не нужен. Приватные ключи остаются на ваших устройствах.',
                                'No phone number is required. Private keys stay on your devices.',
                              ),
                      ),
                      const SizedBox(height: 24),
                      if (editingServer &&
                          step != 1 &&
                          !verifiedRegistrationHere &&
                          !resuming &&
                          draft == null)
                        field(
                          endpoint,
                          tr('Сервер HTTPS', 'HTTPS server'),
                          help: tr(
                            'Введите адрес, полученный от организатора или администратора сервера.',
                            'Enter the address supplied by your organizer or server administrator.',
                          ),
                          example: 'https://chat.example.org',
                          keyboard: TextInputType.url,
                        )
                      else if (endpoint.text.isNotEmpty)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(tr('Сервер аккаунта', 'Account server')),
                          subtitle: Text(endpoint.text),
                          trailing:
                              step != 1 &&
                                  !verifiedRegistrationHere &&
                                  !resuming &&
                                  draft == null
                              ? IconButton(
                                  tooltip: tr(
                                    'Изменить сервер',
                                    'Change server',
                                  ),
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: busy
                                      ? null
                                      : () => setState(
                                          () => editingServer = true,
                                        ),
                                )
                              : null,
                        ),
                      if (step != 1)
                        field(
                          username,
                          tr('Уникальный @username', 'Unique @username'),
                          help: tr(
                            'От 3 до 32 символов: строчные латинские буквы, цифры и знак _.',
                            'Use 3–32 lowercase letters (a–z), digits or underscores.',
                          ),
                          example: 'marina_24',
                          min: 3,
                          max: 32,
                        ),
                      if (step == 0)
                        field(
                          displayName,
                          tr('Имя в профиле', 'Name on profile'),
                          max: 64,
                        ),
                      if (step == 0)
                        field(
                          email,
                          tr('Электронная почта', 'Email'),
                          help: tr(
                            'Укажите почту, на которую придёт код подтверждения.',
                            'Enter the email address where you will receive your verification code.',
                          ),
                          max: 254,
                          keyboard: TextInputType.emailAddress,
                        ),
                      if (step == 0 || (step == 2 && needsAccountPassword))
                        field(
                          password,
                          tr('Пароль аккаунта', 'Account password'),
                          help: step == 0
                              ? tr(
                                  'Придумайте уникальный пароль из 16–256 символов и сохраните в менеджере паролей. Он также открывает переписку на этом устройстве.',
                                  'Choose a unique password of 16–256 characters and save it in your password manager. It also unlocks chats on this device.',
                                )
                              : tr(
                                  'Введите пароль, который указали при регистрации.',
                                  'Enter the password you chose at registration.',
                                ),
                          secret: true,
                          min: legacy ? 12 : 16,
                        ),
                      if (step == 0)
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: remembered,
                          onChanged: busy
                              ? null
                              : (v) => setState(() => remembered = v == true),
                          title: Text(
                            tr(
                              'Я запомнил или сохранил пароль',
                              'I remember or have saved my password',
                            ),
                          ),
                        ),
                      if (step == 1)
                        field(
                          verification,
                          tr('Код из письма', 'Email verification code'),
                          help: tr(
                            'Скопируйте код целиком из письма SecureMesh.',
                            'Paste the entire code from the SecureMesh email.',
                          ),
                          secret: true,
                          max: 128,
                        ),
                      if (step == 2 &&
                          !resuming &&
                          !verifiedRegistrationHere &&
                          draft == null)
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => setState(() {
                                  legacy = !legacy;
                                  password.clear();
                                  localPassword.clear();
                                  revealed.clear();
                                  error = null;
                                }),
                          child: Text(
                            legacy
                                ? tr(
                                    'Вход с единым паролем',
                                    'Use single-password sign-in',
                                  )
                                : tr(
                                    'Вход в аккаунт старой версии',
                                    'Sign in to a legacy account',
                                  ),
                          ),
                        ),
                      if (step == 2 && legacy && !resuming) ...[
                        Text(
                          tr(
                            'Только для старых аккаунтов: их пароль передаётся серверу по HTTPS. Здесь нельзя вводить единый пароль нового аккаунта.',
                            'For legacy accounts only: the old account password is sent to the server over HTTPS. Never enter a new account’s single password here.',
                          ),
                        ),
                        field(
                          localPassword,
                          tr(
                            'Пароль локального хранилища',
                            'Local store passphrase',
                          ),
                          help: tr(
                            'Придумайте отдельную фразу длиной от 16 до 256 символов. Сохраните её, чтобы открывать переписку на этом устройстве.',
                            'Choose a separate passphrase of 16–256 characters. Keep it to unlock your chats on this device.',
                          ),
                          secret: true,
                          min: 16,
                        ),
                      ],
                      if (error != null)
                        Semantics(
                          liveRegion: true,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: Text(
                              ru ? error!.ru : error!.en,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        ),
                      FilledButton(
                        onPressed:
                            busy ||
                                (step == 0 && !remembered) ||
                                (resuming && setup == null && !profileComplete)
                            ? null
                            : submit,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            busy
                                ? tr('Выполняем…', 'Working…')
                                : step == 0
                                ? tr('Создать аккаунт', 'Create account')
                                : step == 1
                                ? tr('Подтвердить почту', 'Verify email')
                                : profileComplete || draft?['session'] != null
                                ? tr('Завершить вход', 'Finish signing in')
                                : resuming
                                ? tr('Продолжить вход', 'Continue sign-in')
                                : tr('Войти', 'Sign in'),
                          ),
                        ),
                      ),
                      if (step != 1 &&
                          draft == null &&
                          !resuming &&
                          !profileComplete)
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => setState(() {
                                  password.clear();
                                  localPassword.clear();
                                  revealed.clear();
                                  remembered = false;
                                  legacy = false;
                                  step = step == 0 ? 2 : 0;
                                  if (step == 0 && verifiedRegistrationHere) {
                                    verifiedRegistrationHere = false;
                                    password.clear();
                                    localPassword.clear();
                                  }
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
