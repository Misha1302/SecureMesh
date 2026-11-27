import 'chat_folders.dart';
import 'display_name.dart';
import 'identity_comparison.dart';
import 'chat_preview.dart';
import 'contact_profile.dart';
import 'attachment_transfer.dart';
import 'conversation_media.dart';
import 'profile_photo.dart';
import 'profile_text.dart';
import 'notification_preferences.dart';
import 'public_channels.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'local_client.dart';
import 'linked_roster.dart';
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
    this.saveChanges,
    this.mediaAttachments,
    this.onMute,
    required this.openChat,
    this.channelApi,
    this.onDirectory,
    this.russian = true,
  });
  final Map<String, dynamic> profile;
  final DisplayNameApi? channelApi;
  final LocalCrypto crypto;
  final Future<void> Function(String group, bool muted)? onMute;
  final ValueChanged<List<dynamic>>? onDirectory;
  final PrivateAttachments Function(String group)? mediaAttachments;
  final HttpsRequest api;
  final Future<void> Function(Map<String, dynamic>) saveProfile;
  final Future<void> Function(
    Map<String, dynamic> changes,
    Set<String> removed,
  )?
  saveChanges;
  final Future<void> Function(String, String, String, String) openChat;
  final bool russian;
  @override
  State<AccountHub> createState() => _AccountHubState();
}

class _AccountHubState extends State<AccountHub> {
  late Map<String, dynamic> account;
  final chatSearch = TextEditingController();
  final username = TextEditingController(),
      enrollmentId = TextEditingController();
  List<dynamic> requests = [], welcomes = [], chats = [], rosterWelcomes = [];
  Map<String, dynamic>? certificate;
  String? actionError, refreshError;
  String? get error => actionError ?? refreshError;
  String chatQuery = '';
  Map<String, ChatPreview> previews = {};
  String? selectedFolder;
  bool archiveOpen = false;
  ChatFolderMap get folders => readChatFolders(account['chatFolders']);

  Future<void> chooseFolders(String id) async {
    final value = await showDialog<ChatFolderMap>(
      context: context,
      builder: (_) => ChatFolderPicker(folders, id, tr),
    );
    if (!mounted || value == null) return;
    await save({...account, 'chatFolders': value});
    if (!value.containsKey(selectedFolder)) selectedFolder = null;
  }

  bool composing = false;
  bool channelsOpen = false;
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
    final members = folders[selectedFolder]?.toSet();
    final matches = chats.where(
      (chat) =>
          archived.contains(chat['id']) == archiveOpen &&
          (archiveOpen || members == null || members.contains(chat['id'])) &&
          ((chat['peerName'] as String).toLowerCase().contains(chatQuery) ||
              (peerDisplayName(chat['peerDisplayName']) ?? '')
                  .toLowerCase()
                  .contains(chatQuery)),
    );
    final result = matches.toList();
    final positions = {
      for (final (index, chat) in result.indexed) chat['id']: index,
    };
    result.sort((a, b) {
      final firstPinned = pinned.contains(a['id']);
      final secondPinned = pinned.contains(b['id']);
      if (firstPinned != secondPinned) return firstPinned ? -1 : 1;
      final order = (previews[b['id']]?.timeMs ?? 0).compareTo(
        previews[a['id']]?.timeMs ?? 0,
      );
      return order != 0
          ? order
          : positions[a['id']]!.compareTo(positions[b['id']]!);
    });
    return result;
  }

  Iterable<MapEntry<dynamic, dynamic>> get localOnly {
    final saved = account['verifiedChats'] as Map?;
    if (saved == null || (!directoryLoaded && refreshError == null)) {
      return const [];
    }
    final live = chats.map((c) => c['id']).toSet();
    final members = folders[selectedFolder]?.toSet();
    return saved.entries.where(
      (item) =>
          item.key is String &&
          item.value is Map &&
          !live.contains(item.key) &&
          (archiveOpen || members == null || members.contains(item.key)) &&
          ids('archivedChats').contains(item.key) == archiveOpen &&
          (item.value['name']?.toString() ?? '').toLowerCase().contains(
            chatQuery,
          ),
    );
  }

  Future<void> readLocalHistory(String group, String name) async {
    final timeline = await widget.crypto('timeline', {'group': group});
    if (!mounted) return;
    final rows = (timeline['messages'] as List)
        .where((row) => row['text'] is String)
        .toList();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(name),
        content: SizedBox(
          width: 400,
          child: rows.isEmpty
              ? Text(
                  tr(
                    'На этом устройстве нет сообщений.',
                    'No messages on this device.',
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: rows.length,
                  itemBuilder: (_, i) => ListTile(
                    title: SelectableText(rows[i]['text'] as String),
                    subtitle: Text(
                      rows[i]['own'] == true ? tr('Вы', 'You') : name,
                    ),
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
    );
  }

  bool directoryLoaded = false;
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
  void didUpdateWidget(AccountHub oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keep fields changed by the shell, including active chat and refreshed
    // credentials, even when the running directory request began earlier.
    for (final entry in widget.profile.entries) {
      if (!oldWidget.profile.containsKey(entry.key) ||
          oldWidget.profile[entry.key] != entry.value) {
        account[entry.key] = entry.value;
      }
    }
    for (final key in oldWidget.profile.keys) {
      if (!widget.profile.containsKey(key)) account.remove(key);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    chatSearch.dispose();
    username.dispose();
    enrollmentId.dispose();
    super.dispose();
  }

  Future<void> save(Map<String, dynamic> value) async {
    if (!mounted) return;
    final changes = <String, dynamic>{
      for (final entry in value.entries)
        if (!account.containsKey(entry.key) ||
            account[entry.key] != entry.value)
          entry.key: entry.value,
    };
    final removed = account.keys
        .where((key) => !value.containsKey(key))
        .toSet();
    if (changes.isEmpty && removed.isEmpty) return;
    if (widget.saveChanges case final persist?) {
      await persist(changes, removed);
    } else {
      await widget.saveProfile(
        {...account, ...changes}
          ..removeWhere((key, _) => removed.contains(key)),
      );
    }
    account = {...account, ...changes}
      ..removeWhere((key, _) => removed.contains(key));
  }

  Future<Map<String, ChatPreview>> localPreviews(List<dynamic> existing) async {
    final saved = account['verifiedChats'] as Map?;
    if (saved == null || existing.isEmpty) return {};
    final identities = existing.whereType<Map>().where((chat) {
      final entry = saved[chat['id']];
      return entry is Map &&
          entry['key'] is String &&
          entry['device'] is String &&
          entry['key'] == chat['peerKey'] &&
          entry['device'] == chat['peerDevice'] &&
          entry['name'] == chat['peerName'];
    }).toList();
    if (identities.isEmpty) return {};
    try {
      final result = await widget.crypto('conversation_previews');
      final rows = result['previews'];
      if (rows is! Map) return {};
      return {
        for (final chat in identities)
          chat['id'] as String: ?ChatPreview.read(rows[chat['id']]),
      };
    } catch (_) {
      // Older cores can still open conversations without directory previews.
      return {};
    }
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
      if (!canUse && mounted) {
        setState(() {
          trusted = false;
          previews = {};
          certificate = null;
        });
      }
      await save({
        ...account,
        'userId': me['userId'],
        'trustState': me['trustState'],
      });
      if (canUse) {
        final incoming = await widget.api('/v1/chat-requests') as List;
        final pending = await widget.api('/v1/crypto/welcomes') as List;
        final existing = await widget.api('/v1/conversations') as List;
        final linked = await widget.api('/v1/roster/welcomes') as List;
        final summaries = await localPreviews(existing);
        if (mounted) {
          setState(() {
            previews = summaries;
            requests = incoming;
            welcomes = pending;
            rosterWelcomes = linked;
            chats = existing;
            directoryLoaded = true;
            trusted = true;
            refreshError = null;
          });
          widget.onDirectory?.call(existing);
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
            previews = {};
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
              : failure is ApiFailure && failure.code == 'CONTACT_REQUEST_LIMIT'
              ? tr(
                  'Достигнут суточный лимит запросов этому пользователю.',
                  'Daily request limit for this contact reached.',
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

  Future<ContactKeyState> contactKeyState(
    String peer,
    String key, {
    String? group,
    String? name,
  }) async {
    final saved = (account['verifiedChats'] as Map?)?[group] as Map?;
    final pin = await widget.crypto('peer_key_status', {
      'identity': peer,
      'public_key': key,
    });
    final status = pin['status'];
    if (status == 'changed' ||
        (saved != null && (saved['device'] != peer || saved['key'] != key))) {
      return ContactKeyState.changed;
    }
    if (status == 'matches' && saved != null && saved['name'] == name) {
      return ContactKeyState.verified;
    }
    if (status != 'unknown' && status != 'matches') {
      throw StateError('UNKNOWN_PEER_KEY_STATUS');
    }
    return ContactKeyState.unverified;
  }

  Future<bool> compare(
    String peer,
    String key, {
    String? group,
    String? name,
    bool pinAfterConfirmation = true,
    bool recheck = false,
  }) async {
    final keyState = await contactKeyState(peer, key, group: group, name: name);
    if (!mounted) return false;
    if (keyState == ContactKeyState.changed) {
      setState(
        () => actionError = tr(
          'Ключ или устройство собеседника изменились. Чат заблокирован. Свяжитесь с собеседником другим способом.',
          'Your contact’s key or device changed. This chat is blocked. Contact them through another channel.',
        ),
      );
      return false;
    }
    if (!recheck && keyState == ContactKeyState.verified) return true;
    final own = await widget.crypto('identity');
    if (!mounted) return false;
    if (!await compareDeviceKey(
          context,
          own['public_key'] as String,
          key,
          tr,
        ) ||
        !mounted) {
      return false;
    }
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
    final name = username.text
        .trim()
        .replaceFirst(RegExp(r'^@'), '')
        .toLowerCase();
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
    await save({...account}..remove('outgoingRequest'));
    username.clear();
    if (mounted) setState(() => composing = false);
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
    final invitation = requests
        .where((r) => r['id'] == welcome['invitation'])
        .firstOrNull;
    if (invitation != null &&
        (invitation['outgoing'] != false ||
            invitation['accepted'] != true ||
            invitation['senderDevice'] != peer ||
            invitation['senderKey'] != key)) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('Чат заблокирован', 'Chat blocked')),
          content: Text(
            tr(
              'Данные отправителя не совпадают с принятым запросом. Проверьте их с собеседником.',
              'The sender does not match the accepted invitation. Check the details with your contact.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('Закрыть', 'Close')),
            ),
          ],
        ),
      );
      return;
    }
    if (!await compare(peer, key)) return;
    await widget.crypto('directory_join', Map<String, dynamic>.from(welcome));
    await widget.api('/v1/crypto/welcomes/${welcome['group']}/ack', data: {});
    await widget.openChat(
      welcome['group'] as String,
      peer,
      invitation?['username'] as String? ?? tr('Собеседник', 'Contact'),
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
            final code = deviceFingerprint(identity['public_key'] as String);
            if (code == null) throw StateError('Invalid device key');
            await showOwnDeviceCode(context, code, tr);
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

  Future<void> publishLinkedPackage() async {
    final package = await widget.crypto('keypackage');
    await widget.api(
      '/v1/crypto/keypackages',
      data: {'payload': package['keypackage']},
    );
  }

  Future<void> manageRoster(Map chat, bool adding) async {
    final group = chat['id'] as String;
    final state = await widget.crypto('roster_state', {'group': group});
    final members = state['members'] as List;
    if (adding && members.length != 2) {
      throw StateError('ONLY_ONE_EXTRA_DEVICE_SUPPORTED');
    }
    final devices = await widget.api('/v1/devices') as List;
    if (!mounted) return;
    final input = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          adding
              ? tr('Добавить устройство в чат', 'Add device to conversation')
              : tr(
                  'Удалить устройство из чата',
                  'Remove device from conversation',
                ),
        ),
        content: TextField(
          controller: input,
          decoration: InputDecoration(
            labelText: adding
                ? tr(
                    'Номер подтверждённой заявки',
                    'Approved enrollment identifier',
                  )
                : tr('ID отозванного устройства', 'Revoked device ID'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, input.text.trim()),
            child: Text(tr('Далее', 'Next')),
          ),
        ],
      ),
    );
    input.dispose();
    if (value == null || !mounted) return;
    uuidBytes(value);
    final me = account['deviceId'] as String;
    final epoch = state['epoch'];
    final actionName = adding ? 'add' : 'remove';
    Map<String, dynamic> cert = {};
    String target = value;
    String? key;
    if (adding) {
      final grant = await widget.api('/v1/devices/enrollment/$value') as Map;
      final parts = utf8
          .decode(base64Decode(grant['payload'] as String))
          .split('\n');
      if (parts.length != 8 ||
          grant['approverId'] != me ||
          grant['activationSignature'] is! String) {
        throw StateError('ACTIVATED_ENROLLMENT_REQUIRED');
      }
      target = parts[2];
      key = parts[3];
      cert = {
        'account': account['userId'],
        'payload': grant['payload'],
        'candidate_signature': grant['candidateSignature'],
        'grant_signature': grant['grantSignature'],
        'activation_signature': grant['activationSignature'],
      };
    }
    final device = devices.where((item) => item['id'] == target).firstOrNull;
    if (device == null || device['revoked'] == adding || target == me) {
      throw StateError('DEVICE_NOT_ELIGIBLE');
    }
    if (!adding) {
      key =
          members.where((m) => m['device'] == target).firstOrNull?['key']
              as String?;
    }
    if (key == null || key != device['publicKey']) {
      throw StateError('DEVICE_KEY_MISMATCH');
    }
    if (!mounted ||
        !await confirmRosterChange(
          context,
          group: group,
          description: '$actionName $target\n$key',
          tr: tr,
        )) {
      return;
    }
    final args = {
      'group': group,
      'epoch': epoch,
      'device': target,
      'approver': me,
      'action': actionName,
    };
    final pending = (await widget.crypto('roster_pending', {
      'group': group,
    }))['transition'];
    Map transition;
    if (pending is Map) {
      if (pending['device'] != target || pending['action'] != actionName) {
        throw StateError('DIFFERENT_PENDING_TRANSITION');
      }
      transition = pending;
    } else {
      await widget.crypto('roster_approve', {
        ...args,
        ...cert,
        'confirmed': true,
      });
      final id = newUuid();
      final package = adding
          ? await widget.api(
              '/v1/conversations/$group/roster-packages/$target/$id',
              data: {},
            ) as Map
          : <String, dynamic>{};
      transition = await widget.crypto('roster_stage', {
        ...args,
        'id': id,
        ...Map<String, dynamic>.from(package),
      });
    }
    final ack = await widget.api(
      '/v1/roster/transitions',
      data: Map<String, dynamic>.from(transition),
    ) as Map;
    await widget.crypto('roster_saved', {
      'group': group,
      'id': transition['id'],
      ...Map<String, dynamic>.from(ack),
    });
  }

  Future<void> joinLinked(Map welcome) async {
    final group = welcome['group'] as String;
    final chat = chats.where((c) => c['id'] == group).firstOrNull;
    if (chat == null) throw StateError('CHAT_NOT_AVAILABLE');
    final peer = chat['peerDevice'] as String;
    final key = chat['peerKey'] as String;
    final approver = welcome['committer'] as String;
    final own = account['deviceId'] as String;
    final expected = [own, approver, peer];
    if (expected.toSet().length != 3 || welcome['device'] != own) {
      throw StateError('ROSTER_NOT_SUPPORTED');
    }
    if (!await compare(
      peer,
      key,
      group: group,
      name: chat['peerName'] as String,
    )) {
      return;
    }
    if (!mounted ||
        !await confirmRosterChange(
          context,
          group: group,
          description: '${expected.join('\n')}\n$peer: $key',
          tr: tr,
        )) {
      return;
    }
    await widget.crypto('roster_join', {
      'transition': welcome,
      'expected_members': expected,
      'confirmed': true,
    });
    // Persist the verified chat before acknowledging its Welcome. Retry is idempotent.
    await save({
      ...account,
      'verifiedChats': {
        ...?account['verifiedChats'] as Map?,
        group: {'device': peer, 'key': key, 'name': chat['peerName']},
      },
    });
    await widget.api(
      '/v1/acks',
      data: {'conversationId': group, 'sequence': welcome['seq']},
    );
    await widget.openChat(group, peer, chat['peerName'] as String, key);
  }

  @override
  Widget build(BuildContext context) =>
      channelsOpen && trusted && widget.channelApi != null
      ? PublicChannels(
          api: widget.channelApi!,
          russian: widget.russian,
          close: () => setState(() => channelsOpen = false),
        )
      : _hub(context);

  Widget _hub(BuildContext context) {
    final visible = trusted ? visibleChats() : const [];
    final pinned = ids('pinnedChats');
    final header = <Widget>[
      Row(
        children: [
          Expanded(
            child: Text(
              trusted ? tr('Чаты', 'Chats') : tr('Ваш аккаунт', 'Your account'),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          IconButton(
            tooltip: tr('Обновить', 'Refresh'),
            onPressed: blocked ? null : refresh,
            icon: const Icon(Icons.refresh),
          ),
          if (trusted)
            IconButton.filled(
              tooltip: composing
                  ? tr('Закрыть форму', 'Close composer')
                  : tr('Новый чат', 'New chat'),
              icon: Icon(composing ? Icons.close : Icons.edit_outlined),
              onPressed: () => setState(() => composing = !composing),
            ),
        ],
      ),
      const SizedBox(height: 12),
      if (error != null)
        Semantics(
          liveRegion: true,
          child: Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
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
                'На старом устройстве откройте раздел «Чат». Вернитесь к списку чатов, откройте «Подключение устройств» и сравните ключи.',
                'On your old device, open Chat. Return to the chat list, open Link devices, and compare the device keys.',
              ),
            ),
        ],
      ] else ...[
        if (composing) ...[
          const SizedBox(height: 8),
          TextField(
            controller: username,
            autofocus: true,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => action(invite),
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
          const SizedBox(height: 12),
        ],
        for (final welcome in rosterWelcomes)
          ListTile(
            title: Text(
              tr(
                'Приглашение для связанного устройства',
                'Linked-device conversation invitation',
              ),
            ),

            onTap: blocked
                ? null
                : () => action(() => joinLinked(welcome as Map)),
          ),
        if (!directoryLoaded && fetching)
          const LinearProgressIndicator()
        else if (directoryLoaded &&
            chats.isEmpty &&
            localOnly.isEmpty &&
            !composing &&
            requests.isEmpty &&
            welcomes.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text(
              tr(
                'Пока нет чатов. Нажмите «Новый чат», чтобы найти собеседника по имени пользователя.',
                'No chats yet. Choose New chat to start with a username.',
              ),
            ),
          ),
        if (chats.isNotEmpty ||
            (account['verifiedChats'] as Map? ?? {}).isNotEmpty) ...[
          TextField(
            key: const ValueKey('search-chats'),
            controller: chatSearch,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              suffixIcon: chatSearch.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: tr('Очистить поиск', 'Clear search'),
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        chatSearch.clear();
                        setState(() => chatQuery = '');
                      },
                    ),
              labelText: tr('Поиск по чатам', 'Search chats'),
            ),
            onChanged: (value) => setState(() {
              chatQuery = value
                  .trim()
                  .replaceFirst(RegExp(r'^@'), '')
                  .toLowerCase();
            }),
          ),
          if (!archiveOpen && folders.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final folder in <String?>[null, ...folders.keys])
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 6),
                      child: ChoiceChip(
                        label: Text(folder ?? tr('Все', 'All')),
                        selected: selectedFolder == folder,
                        onSelected: (_) =>
                            setState(() => selectedFolder = folder),
                      ),
                    ),
                ],
              ),
            ),
          if (archiveOpen || ids('archivedChats').isNotEmpty)
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
          if (visible.isEmpty && localOnly.isEmpty)
            Text(tr('Чатов не найдено', 'No matching chats')),
        ],
        for (final item in localOnly)
          ListTile(
            leading: const Icon(Icons.history),
            title: Text(
              item.value['name']?.toString() ?? tr('Собеседник', 'Contact'),
            ),
            subtitle: Text(
              tr(
                'Локальная история · только чтение',
                'Local history · read only',
              ),
            ),
            onTap: () => action(
              () => readLocalHistory(
                item.key as String,
                item.value['name']?.toString() ?? tr('Собеседник', 'Contact'),
              ),
            ),
          ),
      ],
    ];
    final footer = <Widget>[
      if (trusted) ...[
        for (final r in requests.where((r) => r['established'] != true))
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
            trailing: r['accepted'] == true
                ? (r['outgoing'] == true
                      ? TextButton(
                          onPressed: blocked
                              ? null
                              : () => action(() => create(r as Map)),
                          child: Text(tr('Создать чат', 'Create chat')),
                        )
                      : null)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (r['outgoing'] != true)
                        IconButton(
                          tooltip: tr('Принять', 'Accept'),
                          icon: const Icon(Icons.check),
                          onPressed: blocked
                              ? null
                              : () => action(() => accept(r as Map)),
                        ),
                      IconButton(
                        tooltip: r['outgoing'] == true
                            ? tr('Отменить запрос', 'Cancel request')
                            : tr('Отклонить запрос', 'Decline request'),
                        icon: const Icon(Icons.close),
                        onPressed: blocked
                            ? null
                            : () => action(() async {
                                await widget.api(
                                  '/v1/chat-requests/${r['id']}/dismiss',
                                  data: {},
                                );
                              }),
                      ),
                    ],
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
        const Divider(),
        if (widget.channelApi != null)
          ListTile(
            leading: const Icon(Icons.campaign_outlined),
            title: Text(tr('Каналы', 'Channels')),
            onTap: () => setState(() => channelsOpen = true),
          ),

        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          leading: const Icon(Icons.devices_outlined),
          title: Text(tr('Подключение устройств', 'Link devices')),
          children: [
            if (account['enrollmentVerified'] == true) ...[
              SelectableText(account['enrollmentId'] as String? ?? ''),
              TextButton(
                onPressed: blocked ? null : () => action(publishLinkedPackage),
                child: Text(
                  tr(
                    'Опубликовать пакет для чата',
                    'Publish linked-device key package',
                  ),
                ),
              ),
            ],
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
        ),
      ],
    ];
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: header.length + visible.length + footer.length,
      itemBuilder: (context, index) {
        if (index < header.length) return header[index];
        final row = index - header.length;
        if (row < visible.length) return _chatRow(visible[row] as Map, pinned);
        return footer[row - visible.length];
      },
    );
  }

  String contactName(Map chat) =>
      peerDisplayName(chat['peerDisplayName']) ?? chat['peerName'] as String;

  Widget contactAvatar(Map chat) => PeerAvatar(
    key: ValueKey(chat['id']),
    username: contactName(chat),
    fetch: widget.api,
    route: peerPhotoRoute(chat['id'], chat['peerPhotoVersion']),
  );

  Future<void> inspectContact(Map chat) async {
    final group = chat['id'] as String;
    final peer = chat['peerDevice'] as String;
    final key = chat['peerKey'] as String;
    final name = chat['peerName'] as String;
    final keyState = await contactKeyState(peer, key, group: group, name: name);
    if (!mounted) return;
    final profileRoute = peerProfileTextRoute(group, peer);
    final verify = await showContactProfile(
      context,
      avatar: contactAvatar(chat),
      displayName: contactName(chat),
      username: name,
      keyState: keyState,
      profileText: keyState == ContactKeyState.verified && profileRoute != null
          ? PeerProfileText(
              load: () => widget.api(profileRoute),
              russian: widget.russian,
            )
          : null,
      openMedia: (profileContext) async {
        ContactKeyState? currentState;
        try {
          currentState = await contactKeyState(
            peer,
            key,
            group: group,
            name: name,
          );
        } catch (_) {
          // An unreadable local pin cannot authorize opening private media.
        }
        if (!mounted ||
            !profileContext.mounted ||
            ModalRoute.of(profileContext)?.isCurrent != true) {
          return;
        }
        if (currentState != ContactKeyState.verified) {
          ScaffoldMessenger.of(profileContext).showSnackBar(
            SnackBar(
              content: Text(
                tr(
                  'Не удалось подтвердить ключ собеседника.',
                  'Could not verify this contact’s device key.',
                ),
              ),
            ),
          );
          return;
        }
        await Navigator.of(profileContext).push<void>(
          MaterialPageRoute(
            builder: (_) => ConversationMedia(
              group: group,
              tr: tr,
              crypto: (op, args) => widget.crypto(op, args),
              createTransfer: widget.mediaAttachments,
              canDownload: () async {
                final current = await widget.api('/v1/conversations') as List;
                if (!mounted ||
                    !current.whereType<Map>().any(
                      (row) =>
                          row['id'] == group &&
                          row['peerDevice'] == peer &&
                          row['peerKey'] == key &&
                          row['peerName'] == name,
                    )) {
                  return false;
                }
                return await contactKeyState(
                      peer,
                      key,
                      group: group,
                      name: name,
                    ) ==
                    ContactKeyState.verified;
              },
            ),
          ),
        );
      },
      verifiedFingerprint: keyState == ContactKeyState.verified
          ? deviceFingerprint(key)
          : null,
      tr: tr,
    );
    if (!verify || !mounted) return;
    if (await compare(peer, key, group: group, name: name, recheck: true)) {
      await save({
        ...account,
        'verifiedChats': {
          ...?account['verifiedChats'] as Map?,
          group: {'device': peer, 'key': key, 'name': name},
        },
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr('Ключ устройства проверен', 'Device key verified'),
            ),
          ),
        );
      }
    }
  }

  bool isMuted(Map chat) => NotificationPreferences.fromProfile(widget.profile)
      .mutedGroups.contains(chat['id']);

  Widget _chatRow(Map c, Set<String> pinned) => ListTile(
    key: ValueKey('chat-${c['id']}'),
    selected: widget.profile['group'] == c['id'],
    selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    contentPadding: const EdgeInsetsDirectional.only(start: 8),
    leading: IconButton(
      tooltip: '${tr('Профиль', 'Profile')} · ${contactName(c)}',
      padding: EdgeInsets.zero,
      onPressed: blocked ? null : () => action(() => inspectContact(c)),
      icon: contactAvatar(c),
    ),
    trailing: PopupMenuButton<String>(
      enabled: !blocked,
      tooltip: tr('Действия с чатом', 'Chat actions'),
      onSelected: (field) => action(
        () => field == 'rosterAdd' || field == 'rosterRemove'
            ? manageRoster(c, field == 'rosterAdd')
            : field == 'mute'
            ? widget.onMute!(c['id'] as String, !isMuted(c))
            : field == 'folders'
            ? chooseFolders(c['id'] as String)
            : toggleChat(field, c['id'] as String),
      ),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'pinnedChats',
          child: Text(
            pinned.contains(c['id'])
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
        if (widget.onMute != null)
          PopupMenuItem(
            value: 'mute',
            child: Text(isMuted(c)
                ? tr('Включить уведомления', 'Unmute chat')
                : tr('Отключить уведомления', 'Mute chat')),
          ),
        PopupMenuItem(
          value: 'folders',
          child: Text(tr('Папки чата', 'Chat folders')),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'rosterAdd',
          child: Text(tr('Добавить связанное устройство', 'Add linked device')),
        ),
        PopupMenuItem(
          value: 'rosterRemove',
          child: Text(
            tr('Удалить отозванное устройство', 'Remove revoked device'),
          ),
        ),
      ],
    ),
    title: Row(
      children: [
        Expanded(
          child: Text(
            peerDisplayName(c['peerDisplayName']) ?? c['peerName'] as String,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (previews[c['id']]?.timeLabel(context) case final label?) ...[
          const SizedBox(width: 6),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      ],
    ),
    subtitle: Row(
      children: [
        if (widget.onMute != null && isMuted(c)) ...[
          Icon(Icons.notifications_off_outlined, size: 16,
              semanticLabel: tr('Уведомления отключены', 'Notifications muted')),
          const SizedBox(width: 4),
        ],
        if (pinned.contains(c['id'])) ...[
          Icon(
            Icons.push_pin_outlined,
            size: 16,
            semanticLabel: tr('Закреплён', 'Pinned'),
          ),
          const SizedBox(width: 4),
        ],
        Expanded(
          child: Text(
            previews[c['id']]?.summary(widget.russian) ?? '@${c['peerName']}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if ((previews[c['id']]?.unread ?? 0) > 0) ...[
          const SizedBox(width: 4),
          Semantics(
            label:
                '${tr('Непрочитанные', 'Unread messages')}: ${previews[c['id']]!.unread}',
            child: ExcludeSemantics(
              child: Badge.count(
                count: previews[c['id']]!.unread,
                backgroundColor: Theme.of(context).colorScheme.primary,
                textColor: Theme.of(context).colorScheme.onPrimary,
              ),
            ),
          ),
        ],
      ],
    ),
    onTap: blocked
        ? null
        : () => action(() async {
            if (rosterWelcomes.any((w) => w['group'] == c['id'])) {
              await joinLinked(
                rosterWelcomes.firstWhere((w) => w['group'] == c['id']) as Map,
              );
              return;
            }
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
  );
}
