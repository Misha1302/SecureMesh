import 'display_name.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'local_client.dart';
import 'transport.dart';

typedef LocalCrypto = Future<Map<String, dynamic>> Function(
  String op, [
  Map<String, dynamic> args,
]);

class AccountHub extends StatefulWidget {
  const AccountHub({
    super.key,
    required this.profile,
    required this.crypto,
    required this.api,
    required this.saveProfile,
    required this.openChat,
    this.russian = true,
  });
  final Map<String, dynamic> profile;
  final LocalCrypto crypto;
  final HttpsRequest api;
  final Future<void> Function(Map<String, dynamic>) saveProfile;
  final Future<void> Function(String, String, String, String) openChat;
  final bool russian;
  @override
  State<AccountHub> createState() => _AccountHubState();
}

class _AccountHubState extends State<AccountHub> {
  late Map<String, dynamic> account;
  final username = TextEditingController(),
      enrollmentId = TextEditingController();
  List<dynamic> requests = [], welcomes = [], chats = [];
  Map<String, dynamic>? certificate;
  String? actionError, refreshError;
  String? get error => actionError ?? refreshError;
  String chatQuery = '';
  bool archiveOpen = false;
  Set<String> ids(String field) =>
      (account[field] as List? ?? const []).whereType<String>().toSet();

  Future<void> toggleChat(String field, String id) async {
    final values = ids(field);
    if (!values.remove(id)) values.add(id);
    await save({...account, field: values.toList()});
  }

  List<dynamic> visibleChats() {
    final pinned = ids('pinnedChats');
    final archived = ids('archivedChats');
    final matches = chats.where(
      (chat) =>
          archived.contains(chat['id']) == archiveOpen &&
          ((chat['peerName'] as String).toLowerCase().contains(chatQuery) ||
                    (peerDisplayName(chat['peerDisplayName']) ?? '').toLowerCase().contains(chatQuery)),
    );
    return [
      ...matches.where((c) => pinned.contains(c['id'])),
      ...matches.where((c) => !pinned.contains(c['id'])),
    ];
  }

  bool working = false, fetching = false, trusted = false;
  bool get blocked => working || fetching;
  Timer? timer;
  String tr(String a, String b) => widget.russian ? a : b;
  @override
  void initState() {
    super.initState();
    account = {...widget.profile};
    trusted =
        account['trustState'] == 'DEVICE_TRUSTED' &&
        account['requiresEnrollment'] != true;
    unawaited(refresh());
    timer = Timer.periodic(
      const Duration(seconds: 8),
      (_) => unawaited(refresh()),
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    username.dispose();
    enrollmentId.dispose();
    super.dispose();
  }

  Future<void> save(Map<String, dynamic> value) async {
    if (!mounted) return;
    await widget.saveProfile(value);
    account = value;
  }

  Future<void> refresh() async {
    if (fetching || working || !mounted) return;
    setState(() => fetching = true);
    try {
      final me = await widget.api('/v1/users/me') as Map;
      final canUse =
          me['trustState'] == 'DEVICE_TRUSTED' &&
          (account['requiresEnrollment'] != true ||
              account['enrollmentVerified'] == true);
      await save({
        ...account,
        'userId': me['userId'],
        'trustState': me['trustState'],
      });
      if (canUse) {
        final incoming = await widget.api('/v1/chat-requests') as List;
        final pending = await widget.api('/v1/crypto/welcomes') as List;
        final existing = await widget.api('/v1/conversations') as List;
        if (mounted) {
          setState(() {
            requests = incoming;
            welcomes = pending;
            chats = existing;
            trusted = true;
            refreshError = null;
          });
        }
      } else {
        Map<String, dynamic>? grant;
        if (account['enrollmentId'] != null) {
          grant = await widget.api(
            '/v1/devices/enrollment/${account['enrollmentId']}',
          ) as Map<String, dynamic>;
        }
        if (mounted) {
          setState(() {
            trusted = false;
            certificate = grant;
            refreshError = null;
          });
        }
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => refreshError = tr(
            'Не удалось обновить аккаунт. Проверьте соединение и повторите.',
            'Could not refresh your account. Check the connection and retry.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => fetching = false);
    }
  }

  Future<void> action(Future<void> Function() run) async {
    if (blocked) return;
    setState(() {
      working = true;
      actionError = null;
    });
    try {
      await run();
    } catch (failure) {
      if (mounted) {
        setState(
          () => actionError =
              failure is ApiFailure && failure.code == 'NO_FRESH_KEYPACKAGE'
              ? tr(
                  'Получатель ещё не опубликовал ключевой пакет. Повторите чуть позже.',
                  'Your contact has not published a fresh key package. Retry shortly.',
                )
              : tr(
                  'Действие не завершено. Проверьте сеть и ключи, затем повторите.',
                  'The action did not complete. Check the connection and device keys, then retry.',
                ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => working = false);
        unawaited(refresh());
      }
    }
  }

  Future<bool> compare(
    String peer,
    String key, {
    String? group,
    String? name,
    bool pinAfterConfirmation = true,
  }) async {
    final saved = (account['verifiedChats'] as Map?)?[group] as Map?;
    final pin = await widget.crypto('peer_key_status', {
      'identity': peer,
      'public_key': key,
    });
    if (!mounted) return false;
    final status = pin['status'];
    if (status == 'changed' ||
        (saved != null && (saved['device'] != peer || saved['key'] != key))) {
      setState(
        () => actionError = tr(
          'Ключ или устройство собеседника изменились. Чат заблокирован. Свяжитесь с собеседником другим способом.',
          'Your contact’s key or device changed. This chat is blocked. Contact them through another channel.',
        ),
      );
      return false;
    }
    if (status == 'matches' && saved != null && saved['name'] == name) {
      return true;
    }
    if (status != 'unknown' && status != 'matches') {
      throw StateError('UNKNOWN_PEER_KEY_STATUS');
    }
    final own = await widget.crypto('identity');
    if (!mounted) return false;
    var checked = false;
    final answer = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: Text(tr('Сравните ключи', 'Compare device keys')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(
                    'Сравните значения по независимому каналу. Сервер не подтверждает личность собеседника.',
                    'Compare these values through an independent channel. The server does not verify your contact’s identity.',
                  ),
                ),
                const SizedBox(height: 16),
                Text(tr('Ваш ключ', 'Your key')),
                SelectableText(own['public_key'] as String),
                const SizedBox(height: 16),
                Text(tr('Устройство собеседника', 'Contact device')),
                SelectableText(peer),
                SelectableText(key),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: checked,
                  onChanged: (v) => update(() => checked = v ?? false),
                  title: Text(tr('Я сравнил ключи', 'I compared these keys')),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Отмена', 'Cancel')),
            ),
            FilledButton(
              onPressed: checked ? () => Navigator.pop(ctx, true) : null,
              child: Text(tr('Подтвердить', 'Confirm')),
            ),
          ],
        ),
      ),
    );
    if (answer != true) return false;
    if (pinAfterConfirmation) {
      await widget.crypto('pin', {
        'identity': peer,
        'public_key': key,
        'confirmed': true,
      });
    }
    return true;
  }

  Future<void> invite() async {
    final name = username.text.trim();
    if (!RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(name)) {
      setState(
        () => actionError = tr(
          'Имя: 3–32 латинские буквы, цифры или _.',
          'Use 3–32 lowercase letters, numbers or _.',
        ),
      );
      return;
    }
    final pending = Map<String, dynamic>.from(
      account['outgoingRequest'] as Map? ?? {},
    );
    final id = pending['username'] == name
        ? pending['id'] as String
        : newUuid();
    await save({
      ...account,
      'outgoingRequest': {'username': name, 'id': id},
    });
    await widget.api('/v1/chat-requests', data: {'id': id, 'username': name});
    username.clear();
  }

  Future<void> accept(Map request) async {
    final peer = request['senderDevice'] as String,
        key = request['senderKey'] as String;
    if (!await compare(peer, key)) return;
    final package = await widget.crypto('keypackage');
    await widget.api(
      '/v1/crypto/keypackages',
      data: {'payload': package['keypackage']},
    );
    await widget.api('/v1/chat-requests/${request['id']}/accept', data: {});
  }

  Future<void> create(Map request) async {
    final peer = request['recipientDevice'] as String,
        key = request['recipientKey'] as String;
    if (!await compare(peer, key)) return;
    final leases = Map<String, dynamic>.from(
      account['pendingLeases'] as Map? ?? {},
    );
    final invitation = request['id'] as String;
    leases[invitation] ??= newUuid();
    await save({...account, 'pendingLeases': leases});
    final existing = await widget.crypto('directory_pending', {
      'invitation': invitation,
    });
    Map<String, dynamic> prepared;
    if (existing['prepared'] == true) {
      prepared = Map<String, dynamic>.from(existing['request'] as Map);
    } else {
      final package = await widget.api(
        '/v1/crypto/keypackages/lease',
        data: {'invitationId': invitation, 'requestId': leases[invitation]},
      ) as Map;
      prepared = await widget.crypto('directory_prepare', {
        'invitation': invitation,
        'lease': leases[invitation],
        'recipient': peer,
        'reference': package['reference'],
        'keypackage': package['keypackage'],
      });
    }
    await widget.api('/v1/conversations/establish', data: prepared);
    await widget.openChat(
      prepared['id'] as String,
      peer,
      request['username'] as String,
      key,
    );
  }

  Future<void> join(Map welcome) async {
    final peer = welcome['sender'] as String,
        key = welcome['senderKey'] as String;
    if (!await compare(peer, key)) return;
    await widget.crypto('directory_join', Map<String, dynamic>.from(welcome));
    await widget.api('/v1/crypto/welcomes/${welcome['group']}/ack', data: {});
    await widget.openChat(
      welcome['group'] as String,
      peer,
      tr('Собеседник', 'Contact'),
      key,
    );
  }

  Widget localKeyButton() => TextButton.icon(
    icon: const Icon(Icons.key),
    label: Text(tr('Показать ключ этого устройства', 'Show this device’s key')),
    onPressed: blocked
        ? null
        : () => action(() async {
            final identity = await widget.crypto('identity');
            if (!mounted) return;
            await showDialog<void>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(tr('Ключ этого устройства', 'This device’s key')),
                content: SingleChildScrollView(
                  child: SelectableText(identity['public_key'] as String),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(tr('Закрыть', 'Close')),
                  ),
                ],
              ),
            );
          }),
  );

  Future<void> startEnrollment() async {
    final request = await widget.api('/v1/devices/enrollment', data: {}) as Map;
    final proof = await widget.crypto('enrollment_proof', {
      'payload': request['payload'],
      'account': account['userId'],
    });
    await widget.api(
      '/v1/devices/enrollment/${request['id']}/proof',
      data: {'signature': proof['signature']},
    );
    await save({
      ...account,
      'enrollmentId': request['id'],
      'requiresEnrollment': true,
      'enrollmentVerified': false,
    });
  }

  Future<void> approveDevice() async {
    final id = enrollmentId.text.trim();
    uuidBytes(id);
    final request = await widget.api('/v1/devices/enrollment/$id') as Map;
    final parts = utf8
        .decode(base64Decode(request['payload'] as String))
        .split('\n');
    // enrollment_approve verifies the signed request and commits the pin.
    if (parts.length != 8 ||
        !await compare(parts[2], parts[3], pinAfterConfirmation: false)) {
      return;
    }
    final signed = await widget.crypto('enrollment_approve', {
      'payload': request['payload'],
      'account': account['userId'],
      'candidate_signature': request['candidateSignature'],
      'confirmed': true,
    });
    if (request['approved'] != true) {
      try {
        await widget.api(
          '/v1/devices/enrollment/$id/approve',
          data: {'signature': signed['signature']},
        );
      } on ApiFailure catch (failure) {
        if (failure.status != 409) rethrow;
        final latest = await widget.api('/v1/devices/enrollment/$id') as Map;
        if (latest['grantSignature'] != signed['signature'] ||
            latest['approverId'] != signed['approver']) {
          rethrow;
        }
      }
    } else if (request['grantSignature'] != signed['signature'] ||
        request['approverId'] != signed['approver']) {
      throw StateError('ENROLLMENT_GRANT_CHANGED');
    }
    enrollmentId.clear();
  }

  Future<void> acceptGrant() async {
    final grant = certificate!;
    if (!await compare(
      grant['approverId'] as String,
      grant['approverKey'] as String,
    )) {
      return;
    }
    final accepted = await widget.crypto('enrollment_accept', {
      'payload': grant['payload'],
      'account': account['userId'],
      'candidate_signature': grant['candidateSignature'],
      'approver': grant['approverId'],
      'grant_signature': grant['grantSignature'],
    });
    await widget.api(
      '/v1/devices/enrollment/${grant['id']}/activate',
      data: {'signature': accepted['activation_signature']},
    );
    await save({
      ...account,
      'enrollmentVerified': true,
      'requiresEnrollment': false,
    });
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Text(
        tr('Ваш аккаунт', 'Your account'),
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 12),
      Text(
        account['username'] as String? ??
            tr('Приватное общение', 'Private messaging'),
      ),
      const SizedBox(height: 16),
      if (error != null)
        Semantics(
          liveRegion: true,
          child: Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: working || fetching ? null : refresh,
          icon: const Icon(Icons.refresh),
          label: Text(tr('Обновить', 'Refresh')),
        ),
      ),
      if (!trusted) ...[
        Text(
          tr('Устройство ожидает подтверждения', 'Device approval required'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        Text(
          tr(
            'Пароль открыл только аккаунт. Подтвердите устройство с уже доверенного устройства. Перенос старой истории и восстановление в этой альфе ещё недоступны.',
            'Your password unlocked only the account. Approve this device from an existing trusted device. History transfer and recovery are not available in this alpha yet.',
          ),
        ),
        const SizedBox(height: 16),
        if (account['enrollmentId'] == null)
          FilledButton(
            onPressed: blocked ? null : () => action(startEnrollment),
            child: Text(
              tr('Создать заявку на подключение', 'Request device approval'),
            ),
          )
        else ...[
          SelectableText(account['enrollmentId'] as String),
          localKeyButton(),
          TextButton(
            onPressed: blocked ? null : () => action(startEnrollment),
            child: Text(
              tr(
                'Создать новую заявку, если срок истёк',
                'Request again if the previous request expired',
              ),
            ),
          ),
          TextButton.icon(
            onPressed: () => Clipboard.setData(
              ClipboardData(text: account['enrollmentId'] as String),
            ),
            icon: const Icon(Icons.copy),
            label: Text(
              tr('Скопировать номер заявки', 'Copy request identifier'),
            ),
          ),
          if (certificate?['approved'] == true)
            FilledButton(
              onPressed: blocked ? null : () => action(acceptGrant),
              child: Text(
                tr(
                  'Проверить подпись подтверждения',
                  'Verify approval signature',
                ),
              ),
            )
          else
            Text(
              tr(
                'На старом устройстве откройте раздел «Чат». Если открыта переписка, нажмите стрелку назад, затем подтвердите заявку и сравните ключи.',
                'On your old device, open Chat. If a conversation is open, go back, then approve the request and compare the keys.',
              ),
            ),
        ],
      ] else ...[
        Text(
          tr('Чаты', 'Chats'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (chats.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              tr(
                'Начните переписку по имени пользователя. Перед отправкой нужно согласие получателя и сравнение ключей.',
                'Start a conversation by username. Your contact must accept and compare keys before messaging.',
              ),
            ),
          ),
        if (chats.isNotEmpty) ...[
          TextField(
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              labelText: tr('Поиск по чатам', 'Search chats'),
            ),
            onChanged: (value) => setState(() {
              chatQuery = value.trim().toLowerCase();
            }),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: Icon(
                archiveOpen ? Icons.arrow_back : Icons.archive_outlined,
              ),
              label: Text(
                archiveOpen
                    ? tr('Все чаты', 'All chats')
                    : tr('Архив', 'Archive'),
              ),
              onPressed: () => setState(() => archiveOpen = !archiveOpen),
            ),
          ),
          if (visibleChats().isEmpty)
            Text(tr('Чатов не найдено', 'No matching chats')),
        ],
        for (final c in visibleChats())
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              child: Text(
                (c['peerName'] as String).isEmpty
                    ? '?'
                    : (c['peerName'] as String).characters.first.toUpperCase(),
              ),
            ),
            trailing: PopupMenuButton<String>(
              enabled: !blocked,
              tooltip: tr('Действия с чатом', 'Chat actions'),
              onSelected: (field) =>
                  action(() => toggleChat(field, c['id'] as String)),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'pinnedChats',
                  child: Text(
                    ids('pinnedChats').contains(c['id'])
                        ? tr('Открепить', 'Unpin')
                        : tr('Закрепить', 'Pin'),
                  ),
                ),
                PopupMenuItem(
                  value: 'archivedChats',
                  child: Text(
                    archiveOpen
                        ? tr('Из архива', 'Unarchive')
                        : tr('В архив', 'Archive chat'),
                  ),
                ),
              ],
            ),
            title: Text(
              peerDisplayName(c['peerDisplayName']) ?? c['peerName'] as String,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text('@${c['peerName']}'),
            onTap: blocked
                ? null
                : () => action(() async {
                    if (await compare(
                      c['peerDevice'] as String,
                      c['peerKey'] as String,
                      group: c['id'] as String,
                      name: c['peerName'] as String,
                    )) {
                      await widget.openChat(
                        c['id'] as String,
                        c['peerDevice'] as String,
                        c['peerName'] as String,
                        c['peerKey'] as String,
                      );
                    }
                  }),
          ),
        const SizedBox(height: 16),
        TextField(
          controller: username,
          enabled: !blocked,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: tr('Имя собеседника', 'Contact username'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            onPressed: blocked ? null : () => action(invite),
            child: Text(tr('Отправить запрос на чат', 'Send chat request')),
          ),
        ),
        for (final r in requests)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(r['username'] as String),
            subtitle: Text(
              r['outgoing'] == true
                  ? (r['accepted'] == true
                        ? tr('Запрос принят', 'Request accepted')
                        : tr('Ожидаем согласия', 'Waiting for acceptance'))
                  : tr('Входящий запрос', 'Incoming request'),
            ),
            trailing: r['outgoing'] == true
                ? (r['accepted'] == true
                      ? TextButton(
                          onPressed: blocked
                              ? null
                              : () => action(() => create(r as Map)),
                          child: Text(tr('Создать чат', 'Create chat')),
                        )
                      : null)
                : r['accepted'] == true
                ? null
                : TextButton(
                    onPressed: blocked
                        ? null
                        : () => action(() => accept(r as Map)),
                    child: Text(tr('Принять', 'Accept')),
                  ),
          ),
        for (final w in welcomes)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              tr('Защищённый чат готов', 'Secure conversation is ready'),
            ),
            subtitle: Text(
              tr(
                'Проверьте ключ отправителя перед открытием.',
                'Verify the sender key before opening.',
              ),
            ),
            onTap: blocked ? null : () => action(() => join(w as Map)),
          ),
        const SizedBox(height: 24),
        Text(
          tr('Подключить другое устройство', 'Approve another device'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        localKeyButton(),
        const SizedBox(height: 12),
        TextField(
          controller: enrollmentId,
          enabled: !blocked,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: tr(
              'Номер заявки с нового устройства',
              'Request identifier from the new device',
            ),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: blocked ? null : () => action(approveDevice),
            child: Text(tr('Проверить устройство', 'Verify device')),
          ),
        ),
      ],
    ],
  );
}
