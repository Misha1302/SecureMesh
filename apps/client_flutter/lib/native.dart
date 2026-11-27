import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:material_ui/material_ui.dart';

import 'src/rust/api.dart';
import 'local_client.dart';
import 'session.dart';
import 'delivery_client.dart';
import 'message_markup.dart';
import 'onboarding.dart';
import 'profile_files.dart';
import 'account_hub.dart';
import 'transport.dart';

class CryptoFailure implements Exception {}

class ClientApp extends StatefulWidget {
  const ClientApp({super.key});
  @override
  State<ClientApp> createState() => _ClientAppState();
}

class _ClientAppState extends State<ClientApp> {
  final path = TextEditingController(
    text: Platform.environment['SECUREMESH_PROFILE'] ?? '',
  );
  final pass = TextEditingController();
  final composer = TextEditingController();
  final chatScroll = ScrollController();
  bool showLocalUnlock = (Platform.environment['SECUREMESH_PROFILE'] ?? '')
      .trim()
      .isNotEmpty;
  bool sending = false, unread = false;
  int generation = 0;
  String connectionState = "offline";
  String? sendError, deviceError;
  NativeClient? store;
  HttpClient? http;
  MeshTransport? transport;
  AccountSession? session;
  NativeDelivery? delivery;
  Map<String, dynamic>? profile;
  List<dynamic> messages = [];
  List<dynamic> devices = [];
  Timer? timer;
  bool busy = false,
      loading = false,
      choosing = false,
      online = false,
      lite = false,
      ru = true;
  String? error;
  int tab = 0, failures = 0;
  Future<void> profileWrites = Future.value();
  ThemeMode theme = ThemeMode.system;
  String tr(String a, String b) => ru ? a : b;
  int get queued => messages.where((m) => m['status'] == 'queued').length;
  Future<Map<String, dynamic>> crypto(
    String op, [
    Map<String, dynamic> args = const {},
  ]) async {
    final epoch = generation;
    final current = store;
    if (current == null) throw CryptoFailure();
    try {
      final result = jsonDecode(
        await current.execute(request: jsonEncode({'op': op, ...args})),
      ) as Map<String, dynamic>;
      if (epoch != generation) throw CryptoFailure();
      return result;
    } catch (_) {
      throw CryptoFailure();
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    delivery?.close();
    transport?.close();
    session?.close();
    http?.close(force: true);
    store?.dispose();
    path.dispose();
    pass.dispose();
    composer.dispose();
    chatScroll.dispose();
    super.dispose();
  }

  Future<void> unlock(BuildContext pageContext) async {
    if (loading || store != null) return;
    NativeClient? opening;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      if (!File(path.text.trim()).existsSync()) {
        throw StateError('PROFILE_FILE_MISSING');
      }
      await initializeNativeBridge();
      opening = await NativeClient.open(
        path: path.text.trim(),
        passphrase: pass.text,
      );
      if (!mounted) {
        opening.dispose();
        opening = null;
        return;
      }
      final setup = jsonDecode(
        await opening.execute(request: jsonEncode({'op': 'onboarding_state'})),
      ) as Map;
      if (setup['stage'] == 'prepared' || setup['stage'] == 'authenticated') {
        final originalPath = path.text.trim();
        final secret = pass.text;
        opening.dispose();
        opening = null;
        pass.clear();
        if (!mounted || !pageContext.mounted) return;
        setState(() => loading = false);
        await showAccount(
          pageContext,
          resumePath: originalPath,
          resumePassphrase: secret,
        );
        return;
      }
      final saved = jsonDecode(
        await opening.execute(request: jsonEncode({'op': 'profile'})),
      ) as Map<String, dynamic>;
      if (!mounted) {
        opening.dispose();
        opening = null;
        return;
      }
      profile = saved;
      store = opening;
      opening = null;
      http = nativeHttpClient();
      session = AccountSession(
        http: http!,
        endpoint: Uri.parse(profile!['endpoint'] as String),
        profile: () => profile!,
        persist: (value) => persistProfile(value, sessionOnly: true),
      );
      transport = MeshTransport(
        endpoint: Uri.parse(profile!['endpoint'] as String),
        device: profile!['deviceId'] as String,
        token: () => profile!['accessToken'] as String,
        http: http!,
        https: (route, {data}) => api(route, data: data),
      );
      delivery = NativeDelivery(crypto: crypto, transport: transport!);
      pass.clear();
      await reload();
      timer?.cancel();
      if (profile?['group'] != null) unawaited(pump());
    } catch (_) {
      opening?.dispose();
      transport?.close();
      session?.close();
      delivery?.close();
      transport = null;
      http?.close(force: true);
      store?.dispose();
      store = null;
      profile = null;
      error = tr(
        'Не удалось открыть профиль. Проверьте путь и пароль.',
        'Could not unlock this profile. Check the path and passphrase.',
      );
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> showAccount(
    BuildContext pageContext, {
    bool signIn = false,
    String? resumePath,
    String? resumePassphrase,
  }) => Navigator.of(pageContext).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => AccountOnboarding(
        russian: ru,
        signIn: signIn,
        resumePath: resumePath,
        resumePassphrase: resumePassphrase,
        onReady: (created, secret) async {
          path.text = created;
          pass.text = secret;
          await unlock(pageContext);
          if (store == null) throw CryptoFailure();
        },
      ),
    ),
  );

  Future<void> chooseProfile(BuildContext pageContext) async {
    if (loading || choosing) return;
    setState(() => choosing = true);
    try {
      final files = await localProfiles();
      if (!mounted || !pageContext.mounted) return;
      if (files.isEmpty) {
        setState(
          () => error = tr(
            'Сохранённых профилей пока нет. Создайте аккаунт или войдите.',
            'There are no saved profiles yet. Create an account or sign in.',
          ),
        );
        return;
      }
      final selected = await showDialog<String>(
        context: pageContext,
        builder: (context) => SimpleDialog(
          title: Text(tr('Сохранённые профили', 'Saved profiles')),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: Text(
                tr(
                  'Выберите файл и введите его пароль хранилища. Незавершённый вход продолжится с сохранёнными ключами.',
                  'Choose a file and enter its store passphrase. An interrupted sign-in will continue with its saved keys.',
                ),
              ),
            ),
            for (final file in files)
              SimpleDialogOption(
                onPressed: () => Navigator.of(context).pop(file.path),
                child: Text(file.uri.pathSegments.last),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(tr('Отмена', 'Cancel')),
            ),
          ],
        ),
      );
      if (mounted && selected != null) {
        setState(() {
          path.text = selected;
          pass.clear();
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = tr(
            'Не удалось прочитать список профилей. Проверьте доступ к папке или укажите файл вручную.',
            'Could not list profiles. Check folder access or enter the file path manually.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => choosing = false);
    }
  }

  Future<void> reload({bool follow = false}) async {
    if (profile?['group'] == null) {
      if (mounted) setState(() => messages = []);
      return;
    }
    final nearEnd =
        follow ||
        !chatScroll.hasClients ||
        chatScroll.position.extentAfter < 96;
    final previous = messages.isEmpty ? null : messages.last["id"];
    final result = await crypto('timeline', {'group': profile!['group']});
    if (mounted) {
      setState(() => messages = result['messages'] as List<dynamic>);
      final changed = messages.isNotEmpty && messages.last['id'] != previous;
      if (changed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !chatScroll.hasClients) return;
          if (nearEnd) {
            chatScroll.jumpTo(chatScroll.position.maxScrollExtent);
          } else {
            setState(() => unread = true);
          }
        });
      }
    }
  }

  Future<void> persistProfile(
    Map<String, dynamic> value, {
    bool sessionOnly = false,
  }) {
    final epoch = generation;
    final write = profileWrites.then((_) async {
      if (epoch != generation || profile == null) throw CryptoFailure();
      final updated = sessionOnly
          ? {...profile!, ...value}
          : {
              ...value,
              for (final key in [
                'accessToken',
                'refreshToken',
                'deviceId',
                'expiresIn',
              ])
                key: profile![key],
            };
      await crypto('profile_put', {'profile': updated});
      profile = updated;
    });
    // Preserve the queue after a failed write; this caller still receives the failure.
    profileWrites = write.catchError((_) {});
    return write;
  }

  Future<dynamic> api(
    String route, {
    Map<String, dynamic>? data,
    String? method,
  }) => session!.request(route, data: data, method: method);

  Future<void> pump() async {
    if (busy || store == null || !mounted || profile?['group'] == null) return;
    final epoch = generation;
    busy = true;
    timer?.cancel();
    var nextDelay = const Duration(seconds: 3);
    try {
      final progress = await delivery!.tick(profile!['group'] as String);
      nextDelay = progress.delay;
      failures = 0;
      online = progress.connected;
      connectionState = online ? 'connected' : 'offline';
      lite = progress.weak || delivery!.receiptError != null;
      error = null;
    } catch (failure) {
      if (epoch != generation) return;
      online = false;
      failures++;
      if (failure is CryptoFailure) {
        connectionState = 'keys';
        error = tr(
          'Ошибка ключей или хранилища. Событие не подтверждено; проверьте профиль.',
          'Key or storage error. The event was not acknowledged; check this profile.',
        );
      } else if (failure is ApiFailure &&
          (failure.status == 401 || failure.status == 403)) {
        connectionState = 'auth';
        error = tr(
          'Доступ отозван. Нужен повторный вход через API; очередь сохранена.',
          'Access revoked. Sign in again through the API; your queue is saved.',
        );
      } else if (failure is ApiFailure) {
        connectionState = 'server';
        error = tr(
          'Сервер отклонил запрос. Очередь сохранена; повторите соединение.',
          'Server rejected the request. Your queue is saved; reconnect to retry.',
        );
      } else {
        connectionState = 'offline';
        error = tr(
          'Нет связи с сервером. Очередь сохранена.',
          'Cannot reach the server. Your queue is saved.',
        );
      }
    } finally {
      if (epoch == generation) {
        if (store != null && profile != null) {
          try {
            await reload();
          } catch (_) {
            online = false;
            connectionState = 'keys';
            failures++;
            error = tr(
              'Локальное хранилище недоступно. Заблокируйте профиль и откройте его снова.',
              'Local store is unavailable. Lock and reopen this profile.',
            );
          }
        }
        busy = false;
        if (mounted && store != null && profile?['group'] != null) {
          setState(() {});
          final delay = failures == 0
              ? nextDelay
              : Duration(seconds: min(30, 1 << min(failures, 5)));
          timer = Timer(
            delay +
                Duration(
                  milliseconds: Random().nextInt(
                    delay.inMilliseconds < 1000 ? 100 : 600,
                  ),
                ),
            () => unawaited(pump()),
          );
        }
      }
    }
  }

  String messageId() {
    final r = Random.secure();
    final b = List.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  Future<void> send() async {
    final draft = composer.text;
    final text = draft.trim();
    final epoch = generation;
    if (sending || text.isEmpty || profile?['trustConfirmed'] != true) return;
    bool persisted = false;
    setState(() {
      sending = true;
      sendError = null;
    });
    try {
      await crypto('queue', {
        'group': profile!['group'],
        'id': messageId(),
        'text': text,
      });
      persisted = true;
      if (epoch != generation) return;
      if (composer.text == draft) composer.clear();
      unawaited(pump());
      await reload(follow: true);
    } catch (_) {
      if (mounted && epoch == generation) {
        setState(
          () => sendError = persisted
              ? tr(
                  'Сообщение в очереди. Экран не обновился; откройте профиль снова.',
                  'Message is queued. The view could not refresh; reopen this profile.',
                )
              : tr(
                  'Сообщение не сохранено. Проверьте ключи и повторите отправку.',
                  'Message was not saved. Check your keys and send again.',
                ),
        );
      }
    } finally {
      if (mounted && epoch == generation) setState(() => sending = false);
    }
  }

  void lock() {
    generation++;
    timer?.cancel();
    delivery?.close();
    transport?.close();
    session?.close();
    transport = null;
    http?.close(force: true);
    store?.dispose();
    setState(() {
      store = null;
      showLocalUnlock = true;
      profile = null;
      messages = [];
      devices = [];
      composer.clear();
      pass.clear();
      error = null;
      sendError = null;
      deviceError = null;
      online = false;
      lite = false;
      busy = false;
      sending = false;
      unread = false;
      failures = 0;
      connectionState = "offline";
    });
  }

  Future<void> verifyKeys(BuildContext context) async {
    final me = await crypto('identity');
    if (!context.mounted) return;
    bool confirming = false;
    String? verifyError;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: Text(tr('Сравните ключи устройства', 'Compare device keys')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(
                    'Сравните эти значения с собеседником по независимому каналу.',
                    'Compare these values with your contact through an independent channel.',
                  ),
                ),
                const SizedBox(height: 16),
                Text(tr('Ваш ключ', 'Your key')),
                SelectableText(me['public_key'] as String),
                const SizedBox(height: 16),
                Text(tr('Ключ собеседника', 'Contact key')),
                SelectableText(profile!['peerKey'] as String),
                if (verifyError != null)
                  Text(
                    verifyError!,
                    style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: confirming ? null : () => Navigator.pop(ctx),
              child: Text(tr('Позже', 'Later')),
            ),
            FilledButton(
              onPressed: confirming
                  ? null
                  : () async {
                      update(() => confirming = true);
                      try {
                        await crypto('pin', {
                          'identity': profile!['peerDevice'],
                          'public_key': profile!['peerKey'],
                          'confirmed': true,
                        });
                        final verified = {...profile!, 'trustConfirmed': true};
                        await persistProfile(verified);
                        if (ctx.mounted) Navigator.pop(ctx);
                        if (mounted) setState(() {});
                      } catch (_) {
                        if (ctx.mounted) {
                          update(
                            () => verifyError = tr(
                              'Не удалось закрепить ключ. Подтверждение не сохранено.',
                              'Could not pin this key. Verification was not saved.',
                            ),
                          );
                        }
                      } finally {
                        if (ctx.mounted) update(() => confirming = false);
                      }
                    },
              child: Text(tr('Ключи совпадают', 'Keys match')),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'SecureMesh',
    debugShowCheckedModeBanner: false,
    themeMode: theme,
    theme: ThemeData(
      useMaterial3: true,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3390EC)),
    ),
    darkTheme: ThemeData(
      useMaterial3: true,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF3390EC),
        brightness: Brightness.dark,
      ),
    ),
    home: Builder(
      builder: (ctx) => Scaffold(
        appBar: AppBar(
          title: const Text('SecureMesh'),
          actions: [
            if (store == null)
              TextButton(
                onPressed: loading ? null : () => setState(() => ru = !ru),
                child: const Text('RU / EN'),
              )
            else
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(
                  child: Text(tr('Локальная альфа', 'Local alpha')),
                ),
              ),
          ],
        ),
        body: SafeArea(
          child: store == null
              ? (showLocalUnlock ? unlockScreen(ctx) : welcomeScreen(ctx))
              : LayoutBuilder(
                  builder: (context, size) => Row(
                    children: [
                      if (size.maxWidth >= 760)
                        NavigationRail(
                          selectedIndex: tab,
                          onDestinationSelected: (v) {
                            setState(() => tab = v);
                            if (v == 1) unawaited(loadDevices());
                          },
                          labelType: NavigationRailLabelType.all,
                          destinations: [
                            NavigationRailDestination(
                              icon: const Icon(Icons.chat_bubble_outline),
                              label: Text(tr('Чат', 'Chat')),
                            ),
                            NavigationRailDestination(
                              icon: const Icon(Icons.settings_outlined),
                              label: Text(tr('Настройки', 'Settings')),
                            ),
                          ],
                        ),
                      Expanded(
                        child: tab == 0
                            ? (profile?['group'] == null
                                  ? AccountHub(
                                      russian: ru,
                                      profile: profile!,
                                      crypto: crypto,
                                      api: (route, {data}) =>
                                          api(route, data: data),
                                      saveProfile: persistProfile,
                                      openChat: (group, peer, name, key) async {
                                        final selected = {
                                          ...profile!,
                                          'group': group,
                                          'peerDevice': peer,
                                          'peerName': name,
                                          'peerKey': key,
                                          'trustConfirmed': true,
                                          'verifiedChats': {
                                            ...?profile!['verifiedChats']
                                                as Map?,
                                            group: {
                                              'device': peer,
                                              'key': key,
                                              'name': name,
                                            },
                                          },
                                        };
                                        await persistProfile(selected);
                                        await reload();
                                        if (mounted) setState(() {});
                                        unawaited(pump());
                                      },
                                    )
                                  : chat(ctx))
                            : settings(ctx),
                      ),
                    ],
                  ),
                ),
        ),
        bottomNavigationBar: store != null && MediaQuery.sizeOf(ctx).width < 760
            ? NavigationBar(
                selectedIndex: tab,
                onDestinationSelected: (v) {
                  setState(() => tab = v);
                  if (v == 1) unawaited(loadDevices());
                },
                destinations: [
                  NavigationDestination(
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: tr('Чат', 'Chat'),
                  ),
                  NavigationDestination(
                    icon: const Icon(Icons.settings_outlined),
                    label: tr('Настройки', 'Settings'),
                  ),
                ],
              )
            : null,
      ),
    ),
  );
  Widget welcomeScreen(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr('Добро пожаловать в SecureMesh', 'Welcome to SecureMesh'),
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => showAccount(context),
              child: Text(tr('Создать аккаунт', 'Create account')),
            ),
            OutlinedButton(
              onPressed: () => showAccount(context, signIn: true),
              child: Text(
                tr('Войти на этом устройстве', 'Sign in on this device'),
              ),
            ),
            TextButton(
              onPressed: () => setState(() => showLocalUnlock = true),
              child: Text(
                tr('Открыть сохранённый профиль', 'Open a saved profile'),
              ),
            ),
            TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(tr('Как вернуть доступ', 'Regain access')),
                  content: SingleChildScrollView(
                    child: Text(
                      tr(
                        'Если профиль сохранился, откройте его с паролем хранилища. На новом устройстве войдите в аккаунт и подтвердите подключение со старого устройства. Старая история при подключении не переносится. Если все ключи потеряны, сервер не сможет восстановить переписку.',
                        'If you still have your profile, open it with its store passphrase. To link a new device, sign in and approve it from your existing device. Linking does not transfer earlier messages. If all keys are lost, the server cannot recover your conversations.',
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text(tr('Закрыть', 'Close')),
                    ),
                  ],
                ),
              ),
              child: Text(tr('Как вернуть доступ', 'Regain access')),
            ),
          ],
        ),
      ),
    ),
  );

  Widget unlockScreen(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.lock_outline,
                size: 40,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                tr('Откройте свой профиль', 'Unlock your profile'),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              Text(
                tr(
                  'Ключи и очередь хранятся на этом устройстве в зашифрованной базе.',
                  'Keys and your queue stay in an encrypted database on this device.',
                ),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: path,
                decoration: InputDecoration(
                  labelText: tr('Файл профиля', 'Profile file'),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: tr(
                      'Выбрать сохранённый профиль',
                      'Choose a saved profile',
                    ),
                    onPressed: loading || choosing
                        ? null
                        : () => chooseProfile(context),
                    icon: const Icon(Icons.folder_open),
                  ),
                ),
                autocorrect: false,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: pass,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                onSubmitted: (_) => unlock(context),
                decoration: InputDecoration(
                  labelText: tr('Пароль хранилища', 'Store passphrase'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: loading ? null : () => unlock(context),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    loading
                        ? tr('Открываем…', 'Unlocking…')
                        : tr('Открыть профиль', 'Unlock profile'),
                  ),
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              TextButton(
                onPressed: loading || choosing
                    ? null
                    : () => setState(() {
                        pass.clear();
                        error = null;
                        showLocalUnlock = false;
                      }),
                child: Text(tr('К выбору способа входа', 'Back to welcome')),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  Widget chat(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ListTile(
        leading: IconButton(
          tooltip: tr('Все чаты', 'All chats'),
          onPressed: busy || sending
              ? null
              : () async {
                  timer?.cancel();
                  final updated = {...profile!}..remove('group');
                  await persistProfile(updated);
                  if (mounted) setState(() => messages = []);
                },
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text(profile!['peerName'] as String),
        subtitle: Text(
          profile!['trustConfirmed'] == true
              ? tr(
                  'Приватный чат · ключи проверены',
                  'Private chat · keys verified',
                )
              : tr('Приватный чат · OpenMLS', 'Private chat · OpenMLS'),
        ),
        trailing: IconButton(
          tooltip: tr('Проверить ключи', 'Verify keys'),
          onPressed: () => verifyKeys(context),
          icon: const Icon(Icons.key_outlined),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Row(
          children: [
            Icon(
              online ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                online
                    ? (lite
                          ? tr('Слабая сеть', 'Weak connection')
                          : tr('В сети', 'Connected'))
                    : connectionState == 'keys'
                    ? tr('Проверьте ключи', 'Check keys')
                    : connectionState == 'auth'
                    ? tr('Нужен вход', 'Sign in required')
                    : connectionState == 'server'
                    ? tr('Ошибка сервера', 'Server error')
                    : tr('Офлайн', 'Offline'),
              ),
            ),
            Semantics(
              liveRegion: true,
              child: Text(tr('В очереди: $queued', 'Queued: $queued')),
            ),
            IconButton(
              tooltip: tr('Повторить соединение', 'Reconnect'),
              onPressed: () => unawaited(pump()),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
      ),
      if (profile!['trustConfirmed'] != true)
        MaterialBanner(
          content: Text(
            tr(
              'Перед отправкой сравните ключи собеседника.',
              'Compare your contact’s keys before sending.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => verifyKeys(context),
              child: Text(tr('Сравнить ключи', 'Compare keys')),
            ),
          ],
        ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      const Divider(height: 1),
      Expanded(
        child: messages.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    tr(
                      'Переписка пока пуста. Текст можно поставить в очередь даже без сети.',
                      'No messages yet. You can queue text while offline.',
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView.builder(
                controller: chatScroll,
                padding: const EdgeInsets.all(24),
                itemCount: messages.length,
                itemBuilder: (ctx, i) {
                  final m = messages[i];
                  final own = m['own'] == true;
                  return Semantics(
                    label: own
                        ? tr("Ваше сообщение", "Your message")
                        : tr("Сообщение собеседника", "Message from contact"),
                    child: Align(
                      alignment: own
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: own
                                ? Theme.of(ctx).colorScheme.primaryContainer
                                : Theme.of(ctx)
                                      .colorScheme
                                      .surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              MessageMarkup(m['text'] as String, tr: tr),
                              const SizedBox(height: 6),
                              Text(
                                m['status'] == 'queued'
                                    ? tr(
                                        'В очереди на устройстве',
                                        'Queued on this device',
                                      )
                                    : own
                                    ? tr(
                                        'Сохранено на сервере',
                                        'Saved on server',
                                      )
                                    : tr(
                                        'Сохранено на устройстве',
                                        'Saved on device',
                                      ),
                                style: Theme.of(ctx).textTheme.labelSmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
      if (unread)
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () {
              chatScroll.jumpTo(chatScroll.position.maxScrollExtent);
              setState(() => unread = false);
            },
            icon: const Icon(Icons.arrow_downward),
            label: Text(tr('Новые сообщения', 'New messages')),
          ),
        ),
      if (sendError != null)
        Semantics(
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              sendError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: MessageComposer(
                controller: composer,
                tr: tr,
                onSubmitted: (_) => send(),
              ),
            ),
            const SizedBox(width: 12),
            IconButton.filled(
              onPressed: profile!['trustConfirmed'] == true && !sending
                  ? send
                  : null,
              tooltip: tr('Поставить сообщение в очередь', 'Queue message'),
              icon: const Icon(Icons.arrow_upward),
            ),
          ],
        ),
      ),
    ],
  );
  Future<void> loadDevices() async {
    try {
      final result = await api('/v1/devices') as List<dynamic>;
      if (mounted) setState(() => devices = result);
      if (mounted) setState(() => deviceError = null);
    } catch (_) {
      if (mounted) {
        setState(
          () => deviceError = tr(
            'Не удалось загрузить устройства.',
            'Could not load devices.',
          ),
        );
      }
    }
  }

  Widget settings(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Text(
        tr('Настройки', 'Settings'),
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 24),
      SwitchListTile(
        title: const Text('Русский / English'),
        value: ru,
        onChanged: (v) => setState(() => ru = v),
      ),
      ListTile(
        title: Text(tr('Тема', 'Theme')),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: DropdownButton<ThemeMode>(
            isExpanded: true,
            value: theme,
            items: [
              DropdownMenuItem(
                value: ThemeMode.system,
                child: Text(tr('Системная', 'System')),
              ),
              DropdownMenuItem(
                value: ThemeMode.light,
                child: Text(tr('Светлая', 'Light')),
              ),
              DropdownMenuItem(
                value: ThemeMode.dark,
                child: Text(tr('Тёмная', 'Dark')),
              ),
            ],
            onChanged: (v) => setState(() => theme = v!),
          ),
        ),
      ),
      const SizedBox(height: 24),
      Text(
        tr('Устройства аккаунта', 'Account devices'),
        style: Theme.of(context).textTheme.titleLarge,
      ),
      if (deviceError != null)
        ListTile(
          title: Text(deviceError!),
          trailing: TextButton(
            onPressed: loadDevices,
            child: Text(tr('Повторить', 'Retry')),
          ),
        ),
      for (final d in devices)
        ListTile(
          leading: const Icon(Icons.computer_outlined),
          title: Text(
            d['id'] == profile!['deviceId']
                ? tr('Это устройство', 'This device')
                : tr('Другое устройство', 'Other device'),
          ),
          onTap: () => showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(tr('Идентификатор устройства', 'Device identifier')),
              content: SelectableText(d['id'] as String),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(tr('Закрыть', 'Close')),
                ),
              ],
            ),
          ),
          subtitle: Text(
            d['revoked'] == true
                ? tr('Отозвано', 'Revoked')
                : tr('Активно', 'Active'),
          ),
        ),
      const SizedBox(height: 24),
      Text(
        tr(
          'Локальная альфа без независимого аудита. Медиа, публичные каналы и звонки ещё не подключены.',
          'Local alpha without an independent audit. Media, public channels and calls are not connected yet.',
        ),
      ),
      const SizedBox(height: 24),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: lock,
          icon: const Icon(Icons.lock_outline),
          label: Text(tr('Заблокировать профиль', 'Lock profile')),
        ),
      ),
    ],
  );
}
