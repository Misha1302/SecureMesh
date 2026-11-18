import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import 'src/rust/api.dart';
import 'src/rust/frb_generated.dart';

class CryptoFailure implements Exception {}

class ApiFailure implements Exception {
  final int status;
  final String code;
  ApiFailure(this.status, [this.code = '']);
}

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
  bool sending = false, unread = false;
  int generation = 0;
  String connectionState = "offline";
  String? sendError, deviceError;
  NativeClient? store;
  HttpClient? http;
  Map<String, dynamic>? profile;
  List<dynamic> messages = [];
  List<dynamic> devices = [];
  Timer? timer;
  bool busy = false, loading = false, online = false, lite = false, ru = true;
  String? error;
  int tab = 0, failures = 0;
  bool bridgeReady = false;
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
    store?.dispose();
    http?.close(force: true);
    path.dispose();
    pass.dispose();
    composer.dispose();
    chatScroll.dispose();
    super.dispose();
  }

  Future<void> unlock() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      if (!File(path.text.trim()).existsSync()) {
        throw StateError('PROFILE_FILE_MISSING');
      }
      if (!bridgeReady) {
        try {
          await RustLib.init(
            externalLibrary: ExternalLibrary.open(
              Platform.environment['SECUREMESH_CRYPTO_LIB'] ??
                  '../../src/crypto_core/target/debug/libsecuremesh_crypto.so',
            ),
          );
          bridgeReady = true;
        } on StateError {
          rethrow;
        }
      }
      final opened = await NativeClient.open(
        path: path.text.trim(),
        passphrase: pass.text,
      );
      store = opened;
      profile = await crypto('profile');
      final context = SecurityContext(withTrustedRoots: true);
      final cert = Platform.environment['SECUREMESH_CERT_FILE'];
      if (cert != null) context.setTrustedCertificates(cert);
      http = HttpClient(context: context)
        ..connectionTimeout = const Duration(seconds: 12);
      pass.clear();
      await reload();
      timer?.cancel();
      unawaited(pump());
    } catch (_) {
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

  Future<void> reload({bool follow = false}) async {
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

  Future<dynamic> api(
    String route, {
    Map<String, dynamic>? data,
    String? method,
    bool refreshing = false,
  }) async {
    final epoch = generation;
    final base = Uri.parse(profile!['endpoint'] as String);
    if (base.scheme != 'https') throw StateError('TLS_REQUIRED');
    final req = await http!.openUrl(
      method ?? (data == null ? 'GET' : 'POST'),
      base.resolve(route),
    );
    req.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${profile!['accessToken']}',
    );
    req.headers.contentType = ContentType.json;
    if (data != null) req.write(jsonEncode(data));
    final response = await req.close().timeout(const Duration(seconds: 20));
    final raw = await utf8.decoder.bind(response).join();
    if (epoch != generation) throw ApiFailure(499);
    if (response.statusCode == 401 && !refreshing) {
      final rotated = await api(
        '/v1/auth/refresh',
        data: {'token': profile!['refreshToken']},
        refreshing: true,
      ) as Map<String, dynamic>;
      profile!.addAll(rotated);
      await crypto('profile_put', {'profile': profile});
      return api(route, data: data, method: method, refreshing: true);
    }
    if (response.statusCode >= 400) {
      String code = '';
      try {
        final body = jsonDecode(raw);
        if (body is Map && body['code'] is String) {
          code = body['code'] as String;
        }
      } catch (_) {}
      throw ApiFailure(response.statusCode, code);
    }
    return raw.isEmpty ? null : jsonDecode(raw);
  }

  Future<void> pump() async {
    if (busy || store == null || !mounted) return;
    final epoch = generation;
    busy = true;
    timer?.cancel();
    final started = DateTime.now();
    try {
      final pending = (await crypto('outbox'))['messages'] as List<dynamic>;
      for (final m in pending.take(20)) {
        final ack = await api(
          '/v1/messages',
          data: {
            'conversationId': m['group'],
            'clientMessageId': m['id'],
            'mlsEpoch': m['epoch'],
            'envelopeKind': m['kind'],
            'ciphertext': m['ciphertext'],
          },
        ) as Map<String, dynamic>;
        if (ack['durable'] != true) throw StateError('DURABLE_ACK_REQUIRED');
        await crypto('saved', {
          'group': m['group'],
          'id': m['id'],
          'seq': ack['serverSequence'],
        });
      }
      var cursor =
          (await crypto('cursor', {'group': profile!['group']}))['cursor']
              as String;
      for (var pages = 0; pages < 10; pages++) {
        final query = Uri(
          queryParameters: {
            'conversationId': profile!['group'] as String,
            'cursor': cursor,
            'limit': '6',
          },
        ).query;
        Map<String, dynamic> page;
        try {
          page = await api('/v1/sync?$query') as Map<String, dynamic>;
        } on ApiFailure catch (failure) {
          if (failure.code == 'INVALID_CURSOR' && cursor.isNotEmpty) {
            cursor = '';
            continue;
          }
          rethrow;
        }
        final events = page['messages'] as List<dynamic>;
        for (var i = 0; i < events.length; i++) {
          final m = events[i];
          await crypto('ingest', {
            'group': profile!['group'],
            'id': m['clientMessageId'],
            'sender': m['senderDeviceId'],
            'seq': m['serverSequence'],
            'epoch': m['mlsEpoch'],
            'kind': m['envelopeKind'],
            'ciphertext': m['ciphertext'],
            'digest': m['ciphertextSha256'],
            'cursor': i == events.length - 1 ? page['nextCursor'] : '',
          });
        }
        cursor = page['nextCursor'] as String;
        if (page['hasMore'] != true) break;
      }
      final seq = (await crypto('cursor', {'group': profile!['group']}))['seq'];
      await api(
        '/v1/acks',
        data: {'conversationId': profile!['group'], 'sequence': seq},
      );
      failures = 0;
      online = true;
      connectionState = "connected";
      lite = DateTime.now().difference(started).inMilliseconds > 2500;
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
        if (mounted && store != null) {
          setState(() {});
          final seconds = failures == 0 ? 3 : min(30, 1 << min(failures, 5));
          timer = Timer(
            Duration(milliseconds: seconds * 1000 + Random().nextInt(600)),
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
    store?.dispose();
    http?.close(force: true);
    setState(() {
      store = null;
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
                        await crypto('profile_put', {'profile': verified});
                        profile = verified;
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
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF16685B)),
    ),
    darkTheme: ThemeData(
      useMaterial3: true,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF16685B),
        brightness: Brightness.dark,
      ),
    ),
    home: Builder(
      builder: (ctx) => Scaffold(
        appBar: AppBar(
          title: const Text('SecureMesh'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(child: Text(tr('Локальная альфа', 'Local alpha'))),
            ),
          ],
        ),
        body: SafeArea(
          child: store == null
              ? unlockScreen(ctx)
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
                      Expanded(child: tab == 0 ? chat(ctx) : settings(ctx)),
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
                ),
                autocorrect: false,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: pass,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                onSubmitted: (_) => unlock(),
                decoration: InputDecoration(
                  labelText: tr('Пароль хранилища', 'Store passphrase'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: loading ? null : unlock,
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
              Text(
                tr(
                  'Профили локальной демонстрации создаются командой make seed-demo. Регистрация в интерфейсе ещё не подключена.',
                  'Create local demonstration profiles with make seed-demo. Registration is not connected to this interface yet.',
                ),
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
        leading: const CircleAvatar(child: Icon(Icons.person_outline)),
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
                              SelectableText(m['text'] as String),
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
              child: TextField(
                controller: composer,
                minLines: 1,
                maxLines: 4,
                maxLength: 4000,
                decoration: InputDecoration(
                  labelText: tr('Сообщение', 'Message'),
                  border: const OutlineInputBorder(),
                  counterText: '',
                ),
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
