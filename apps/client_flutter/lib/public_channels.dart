import 'package:material_ui/material_ui.dart';

import 'display_name.dart';
import 'channel_comments.dart';
import 'local_client.dart';
import 'transport.dart';

class PublicChannels extends StatefulWidget {
  const PublicChannels({
    super.key,
    required this.api,
    required this.russian,
    required this.close,
  });
  final DisplayNameApi api;
  final bool russian;
  final VoidCallback close;
  @override
  State<PublicChannels> createState() => _PublicChannelsState();
}

class _PublicChannelsState extends State<PublicChannels> {
  static const path = '/v1/public-channels';
  final search = TextEditingController(),
      slug = TextEditingController(),
      title = TextEditingController(),
      post = TextEditingController(),
      inviteName = TextEditingController();
  List<Map> rooms = [], posts = [], aggregatePosts = [];
  Map? room, pinnedPost;
  int? pinRevision;
  String? directoryCursor, aggregateCursor, error;
  int? feedCursor;
  String activeQuery = '';
  bool restricted = false;
  String? inviteNote;
  bool mine = false, creating = false, busy = false, aggregate = false;
  String? createId, creationKey, postId, postKey;
  String tr(String ru, String en) => widget.russian ? ru : en;
  String get roomPath => '$path/${room!['id']}';

  @override
  void initState() {
    super.initState();
    run(catalog);
  }

  @override
  void dispose() {
    search.dispose();
    slug.dispose();
    title.dispose();
    post.dispose();
    inviteName.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() job) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await job();
    } catch (e) {
      if (!mounted) return;
      error = switch (e) {
        ApiFailure(status: 429) => tr(
          'Слишком много действий. Повторите позже.',
          'Too many actions. Try again later.',
        ),
        ApiFailure(code: 'CHANNEL_PIN_CHANGED') => tr(
          'Закрепление изменилось. Обновите публикации.',
          'The pinned post changed. Refresh posts.',
        ),
        ApiFailure(code: 'CHANNEL_POST_CHANGED') => tr(
          'Публикацию уже изменили. Обновите список перед редактированием.',
          'This post changed. Refresh the list before editing.',
        ),
        ApiFailure(status: 409) => tr(
          'Действие конфликтует с текущим состоянием или достигнут лимит. Для нового канала проверьте адрес.',
          'Conflict or quota reached. If creating a channel, check its handle.',
        ),
        ApiFailure(status: 403) => tr(
          'Для этого действия нужны права владельца или подписка.',
          'This action requires ownership or a subscription.',
        ),
        ApiFailure(status: 404) => tr(
          'Канал уже недоступен. Вернитесь к списку.',
          'This channel is unavailable. Return to the list.',
        ),
        ApiFailure(status: 400) => tr(
          'Проверьте адрес канала и длину текста.',
          'Check the handle and text length.',
        ),
        _ => tr(
          'Не удалось завершить действие. Проверьте соединение и повторите.',
          'Could not complete the action. Check the connection and retry.',
        ),
      };
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> catalog({bool more = false}) async {
    final q = more ? activeQuery : search.text.trim().toLowerCase();
    final params = {
      'q': q,
      'mine': '$mine',
      'includeRestricted': 'true',
      if (more && directoryCursor != null) 'after': directoryCursor!,
    };
    final result = await widget.api(
      Uri(path: path, queryParameters: params).toString(),
    ) as Map;
    if (!mounted) return;
    final page = (result['items'] as List).cast<Map>();
    rooms = more ? [...rooms, ...page] : page;
    directoryCursor = result['next'] as String?;
    activeQuery = q;
  }

  Future<void> feed({bool more = false}) async {
    final url = more ? '$roomPath/posts?before=$feedCursor' : '$roomPath/posts';
    try {
      final result = await widget.api(url) as Map;
      if (!mounted) return;
      final page = (result['items'] as List).cast<Map>();
      posts = more ? [...posts, ...page] : page;
      feedCursor = result['next'] as int?;
      pinnedPost = result['pinned'] as Map?;
      pinRevision = result['pinRevision'] as int?;
    } on ApiFailure catch (e) {
      if (e.status == 401 || e.status == 403 || e.status == 404) {
        posts = [];
        feedCursor = null;
        pinnedPost = null;
        pinRevision = null;
      }
      rethrow;
    }
  }

  Future<void> aggregateFeed({bool more = false}) async {
    final url = Uri(
      path: '$path/feed',
      queryParameters: {
        if (more && aggregateCursor != null) 'before': aggregateCursor!,
      },
    );
    try {
      final result = await widget.api(url.toString()) as Map;
      if (!mounted) return;
      final page = (result['items'] as List).cast<Map>();
      aggregatePosts = more ? [...aggregatePosts, ...page] : page;
      aggregateCursor = result['next'] as String?;
    } on ApiFailure catch (e) {
      if (e.status == 401 || e.status == 403) {
        aggregatePosts = [];
        aggregateCursor = null;
      }
      rethrow;
    }
  }

  Future<void> open(Map target) async {
    room = Map.of(target);
    inviteName.clear();
    inviteNote = null;
    posts = [];
    feedCursor = null;
    pinnedPost = null;
    pinRevision = null;
    post.clear();
    postId = null;
    if (room!['owner'] == true || room!['subscribed'] == true) await feed();
  }

  Future<void> create() async {
    final handle = slug.text.trim().toLowerCase(), name = title.text.trim();
    if (!RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(handle) || name.isEmpty) {
      error = tr(
        'Укажите название и адрес из 3–32 латинских букв, цифр или _.',
        'Enter a title and a 3–32 character handle using a–z, digits or _.',
      );
      return;
    }
    final key = '$handle\n$name\n$restricted';
    if (creationKey != key || createId == null) {
      createId = newUuid();
      creationKey = key;
    }
    final result = await widget.api(
      restricted ? '$path/invite-only' : path,
      data: {'id': createId, 'slug': handle, 'title': name},
    ) as Map;
    if (!mounted) return;
    if (restricted && result['inviteOnly'] != true) {
      throw StateError('Unknown channel visibility');
    }
    creating = false;
    createId = null;
    slug.clear();
    title.clear();
    await open({
      'id': result['id'],
      'slug': handle,
      'title': name,
      'owner': true,
      'inviteOnly': restricted,
      'subscribed': false,
    });
  }

  Future<void> subscribe() async {
    final add = room!['subscribed'] != true;
    await widget.api('$roomPath/subscription', method: add ? 'PUT' : 'DELETE');
    if (!mounted) return;
    room!['subscribed'] = add;
    room!['invited'] = false;
    if (add) {
      await feed();
    } else {
      posts = [];
      feedCursor = null;
      pinnedPost = null;
      pinRevision = null;
      if (room!['inviteOnly'] == true) await closeRoom();
    }
  }

  Future<void> invite() async {
    final name = inviteName.text.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(name)) {
      error = tr(
        'Введите точное имя пользователя без @.',
        'Enter the exact username without @.',
      );
      return;
    }
    await widget.api('$roomPath/invitations', data: {'username': name});
    if (!mounted) return;
    inviteName.clear();
    inviteNote = tr(
      'Если аккаунт существует, приглашение появится в его каналах.',
      'If this account exists, the invitation will appear in its channels.',
    );
  }

  Future<void> revoke() async {
    final name = inviteName.text.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(name)) {
      error = tr(
        'Введите точное имя пользователя без @.',
        'Enter the exact username without @.',
      );
      return;
    }
    if (!await confirm(
          tr(
            'Отозвать доступ к каналу для @$name?',
            'Revoke channel access for @$name?',
          ),
          positive: tr('Отозвать', 'Revoke'),
        ) ||
        !mounted) {
      return;
    }
    await widget.api('$roomPath/revoke-access', data: {'username': name});
    if (!mounted) return;
    inviteName.clear();
    inviteNote = tr(
      'Доступ по этому имени отозван.',
      'Access for this username has been revoked.',
    );
  }

  Future<void> decline() async {
    await widget.api('$roomPath/subscription', method: 'DELETE');
    if (mounted) await closeRoom();
  }

  Future<void> setPin(int? seq) async {
    await widget.api(
      '$roomPath/pin',
      method: 'PUT',
      data: {'seq': seq, 'expectedRevision': pinRevision},
    );
    if (mounted) await feed();
  }

  Future<void> editPost(Map item) async {
    var draft = item['body'] as String;
    final body = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Изменить публикацию', 'Edit post')),
        content: TextFormField(
          initialValue: draft,
          onChanged: (v) => draft = v,
          maxLength: 2048,
          minLines: 1,
          maxLines: 5,
          decoration: InputDecoration(
            labelText: tr('Текст публикации', 'Post text'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, draft.trim()),
            child: Text(tr('Сохранить', 'Save')),
          ),
        ],
      ),
    );
    if (body == null || body.isEmpty || !mounted) return;
    await widget.api(
      '$roomPath/posts/${item['seq']}',
      method: 'PUT',
      data: {'expectedRevision': item['revision'], 'body': body},
    );
    if (mounted) await feed();
  }

  Future<void> publish() async {
    final body = post.text.trim();
    if (body.isEmpty) return;
    if (postId == null || postKey != body) {
      postId = newUuid();
      postKey = body;
    }
    await widget.api(
      '$roomPath/posts',
      data: {'requestId': postId, 'body': body},
    );
    if (!mounted) return;
    post.clear();
    postId = null;
    await feed();
  }

  Future<bool> confirm(String question, {String? positive}) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(question),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Отмена', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(positive ?? tr('Удалить', 'Delete')),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> removeRoom() async {
    if (!await confirm(
          tr(
            'Удалить канал и все его публикации?',
            'Delete this channel and all its posts?',
          ),
        ) ||
        !mounted) {
      return;
    }
    await widget.api(roomPath, method: 'DELETE');
    if (!mounted) return;
    await closeRoom();
  }

  Future<void> removePost(int seq) async {
    if (!await confirm(tr('Удалить публикацию?', 'Delete this post?')) ||
        !mounted) {
      return;
    }
    await widget.api('$roomPath/posts/$seq', method: 'DELETE');
    if (mounted) await feed();
  }

  Future<void> react(String channel, int seq, String? kind) async {
    final summary = await widget.api(
      '$path/$channel/posts/$seq/reaction',
      method: kind == null ? 'DELETE' : 'PUT',
      data: kind == null ? null : {'kind': kind},
    ) as Map;
    if (!mounted) return;
    Map update(Map post) => {...post, 'reactions': summary};
    if (room?['id'] == channel) {
      posts = [
        for (final post in posts) post['seq'] == seq ? update(post) : post,
      ];
    }
    aggregatePosts = [
      for (final post in aggregatePosts)
        post['channelId'] == channel && post['seq'] == seq
            ? update(post)
            : post,
    ];
  }

  String? postEditLabel(Map post) {
    final value = post['editedAt'];
    final editedAt = value is String
        ? DateTime.tryParse(value)?.toLocal()
        : null;
    if (editedAt == null) {
      return (post['revision'] as int? ?? 1) > 1
          ? tr('Изменено', 'Edited')
          : null;
    }
    final localizations = MaterialLocalizations.of(context);
    final date = localizations.formatMediumDate(editedAt);
    final time = localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(editedAt),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    return tr('Изменено $date, $time', 'Edited $date, $time');
  }

  Widget comments(Map post, String channel) => TextButton(
    onPressed: busy
        ? null
        : () => showDialog<void>(
            context: context,
            builder: (_) => ChannelComments(
              api: widget.api,
              russian: widget.russian,
              path: '$path/$channel/posts/${post['seq']}/comments',
            ),
          ),
    child: Text(tr('Комментарии', 'Comments')),
  );

  Widget reactions(Map post, String channel) {
    final summary = post['reactions'];
    if (summary is! Map) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final (kind, icon, name) in [
          ('like', Icons.thumb_up_alt_outlined, tr('Нравится', 'Like')),
          ('heart', Icons.favorite_border, tr('Сердце', 'Heart')),
          ('smile', Icons.sentiment_satisfied_alt, tr('Улыбка', 'Smile')),
        ])
          Tooltip(
            message: name,
            child: ChoiceChip(
              key: ValueKey('reaction-$channel-${post['seq']}-$kind'),
              avatar: Icon(icon, size: 18),
              label: Text(
                '${summary[kind] ?? 0}',
                semanticsLabel: '$name: ${summary[kind] ?? 0}',
              ),
              selected: summary['mine'] == kind,
              showCheckmark: false,
              onSelected: busy
                  ? null
                  : (select) => run(
                      () => react(
                        channel,
                        post['seq'] as int,
                        select ? kind : null,
                      ),
                    ),
            ),
          ),
      ],
    );
  }

  Future<void> closeRoom() async {
    room = null;
    post.clear();
    posts = [];
    feedCursor = null;
    pinnedPost = null;
    pinRevision = null;
    await catalog();
  }

  Widget action(String ru, String en, Future<void> Function() f) => TextButton(
    onPressed: busy ? null : () => run(f),
    child: Text(tr(ru, en)),
  );

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Row(
        children: [
          IconButton(
            tooltip: tr('Назад', 'Back'),
            icon: const Icon(Icons.arrow_back),
            onPressed: busy
                ? null
                : () {
                    if (room != null) {
                      run(closeRoom);
                    } else if (aggregate) {
                      setState(() => aggregate = false);
                    } else if (creating) {
                      setState(() => creating = false);
                    } else {
                      widget.close();
                    }
                  },
          ),
          Expanded(
            child: Text(
              room?['title'] as String? ??
                  (aggregate
                      ? tr('Лента подписок', 'Subscription feed')
                      : tr('Каналы', 'Channels')),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
        ],
      ),
      Text(
        room?['inviteOnly'] == true || (creating && restricted)
            ? tr(
                'Канал по приглашениям. Публикации видны серверу и подписчикам.',
                'Invite-only channel. The server and subscribers can read posts.',
              )
            : tr(
                'Публикации видны серверу. Публичные каналы доступны всем участникам.',
                'The server can read posts. Public channels are open to all accounts.',
              ),
      ),
      if (busy) const LinearProgressIndicator(),
      if (error != null) Semantics(liveRegion: true, child: Text(error!)),
      if (creating) ...[
        TextField(
          enabled: !busy,
          controller: title,
          maxLength: 80,
          decoration: InputDecoration(
            labelText: tr('Название канала', 'Channel title'),
          ),
        ),
        TextField(
          enabled: !busy,
          controller: slug,
          maxLength: 32,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: tr('Адрес канала', 'Channel handle'),
            hintText: 'news_2026',
          ),
        ),
        SwitchListTile(
          value: restricted,
          onChanged: busy
              ? null
              : (value) => setState(() => restricted = value),
          title: Text(tr('Только по приглашению', 'Invite only')),
        ),
        action('Создать канал', 'Create channel', create),
      ] else if (aggregate) ...[
        Text(
          tr(
            'Публикации подписок на публичные каналы.',
            'Posts from your public channel subscriptions.',
          ),
        ),
        action('Обновить ленту', 'Refresh feed', aggregateFeed),
        if (!busy && aggregatePosts.isEmpty)
          Text(tr('Публикаций пока нет.', 'No posts yet.')),
        for (final p in aggregatePosts)
          ListTile(
            title: SelectableText(p['body'] as String),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [
                    p['title'],
                    '@${p['slug']}',
                    MaterialLocalizations.of(context).formatMediumDate(
                      DateTime.parse(p['publishedAt'] as String).toLocal(),
                    ),
                    if (postEditLabel(p) case final String edited) edited,
                  ].join(' · '),
                ),
                reactions(p, p['channelId'] as String),
                comments(p, p['channelId'] as String),
              ],
            ),
          ),
        if (aggregateCursor != null)
          action(
            'Более ранние публикации',
            'Older posts',
            () => aggregateFeed(more: true),
          ),
      ] else if (room == null) ...[
        TextField(
          enabled: !busy,
          controller: search,
          maxLength: 32,
          autocorrect: false,
          onSubmitted: (_) => run(catalog),
          decoration: InputDecoration(
            labelText: tr('Поиск по началу адреса', 'Search by handle prefix'),
            suffixIcon: IconButton(
              onPressed: busy ? null : () => run(catalog),
              icon: const Icon(Icons.search),
              tooltip: tr('Найти', 'Search'),
            ),
          ),
        ),
        Wrap(
          children: [
            TextButton(
              onPressed: busy
                  ? null
                  : () => run(() async {
                      aggregate = true;
                      await aggregateFeed();
                    }),
              child: Text(tr('Лента подписок', 'Subscription feed')),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () => run(() async {
                      mine = !mine;
                      await catalog();
                    }),
              child: Text(
                mine
                    ? tr('Все каналы', 'All channels')
                    : tr('Мои каналы', 'My channels'),
              ),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () => setState(() {
                      creating = true;
                      restricted = false;
                      error = null;
                    }),
              child: Text(tr('Новый канал', 'New channel')),
            ),
          ],
        ),
        if (!busy && rooms.isEmpty)
          Text(tr('Каналы не найдены.', 'No channels found.')),
        for (final c in rooms)
          ListTile(
            title: Text(c['title'] as String),
            subtitle: Text(
              c['invited'] == true
                  ? '@${c['slug']} · ${tr('Приглашение', 'Invitation')}'
                  : c['inviteOnly'] == true
                  ? '@${c['slug']} · ${tr('По приглашению', 'Invite only')}'
                  : '@${c['slug']}',
            ),
            leading: const Icon(Icons.campaign_outlined),
            onTap: busy ? null : () => run(() => open(c)),
          ),
        if (directoryCursor != null)
          action('Ещё каналы', 'More channels', () => catalog(more: true)),
      ] else ...[
        Text('@${room!['slug']}'),
        if (room!['owner'] == true && room!['inviteOnly'] == true) ...[
          TextField(
            controller: inviteName,
            enabled: !busy,
            maxLength: 32,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: tr('Точное имя пользователя', 'Exact username'),
            ),
          ),
          Wrap(
            children: [
              action('Пригласить', 'Invite', invite),
              action('Отозвать доступ', 'Revoke access', revoke),
            ],
          ),
          if (inviteNote != null)
            Semantics(liveRegion: true, child: Text(inviteNote!)),
        ],
        if (room!['owner'] == true) ...[
          TextField(
            controller: post,
            enabled: !busy,
            minLines: 1,
            maxLines: 5,
            maxLength: 2048,
            decoration: InputDecoration(
              labelText: room!['inviteOnly'] == true
                  ? tr('Публикация для подписчиков', 'Post for subscribers')
                  : tr('Публичная публикация', 'Public post'),
            ),
          ),
          action('Опубликовать', 'Publish', publish),
        ] else
          action(
            room!['subscribed'] == true
                ? 'Отписаться'
                : room!['invited'] == true
                ? 'Принять приглашение'
                : 'Подписаться',
            room!['subscribed'] == true
                ? 'Unsubscribe'
                : room!['invited'] == true
                ? 'Accept invitation'
                : 'Subscribe',
            subscribe,
          ),
        if (room!['invited'] == true)
          action('Отклонить приглашение', 'Decline invitation', decline),
        if (room!['owner'] == true || room!['subscribed'] == true) ...[
          action('Обновить публикации', 'Refresh posts', feed),
          if (pinnedPost case final Map pin)
            ListTile(
              title: Text(tr('Закреплённая публикация', 'Pinned post')),
              subtitle: SelectableText(pin['body'] as String),
              trailing: room!['owner'] == true
                  ? IconButton(
                      tooltip: tr('Открепить', 'Unpin'),
                      icon: const Icon(Icons.push_pin_outlined),
                      onPressed: busy ? null : () => run(() => setPin(null)),
                    )
                  : null,
            ),
          if (!busy && posts.isEmpty)
            Text(tr('Публикаций пока нет.', 'No posts yet.')),
          for (final p in posts)
            ListTile(
              title: SelectableText(p['body'] as String),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    [
                      MaterialLocalizations.of(context).formatMediumDate(
                        DateTime.parse(p['publishedAt'] as String).toLocal(),
                      ),
                      if (postEditLabel(p) case final String edited) edited,
                    ].join(' · '),
                  ),
                  reactions(p, room!['id'] as String),
                  comments(p, room!['id'] as String),
                ],
              ),
              trailing: room!['owner'] == true
                  ? PopupMenuButton<String>(
                      enabled: !busy,
                      tooltip: tr('Действия с публикацией', 'Post actions'),
                      onSelected: (value) => run(
                        () => switch (value) {
                          'edit' => editPost(p),
                          'pin' => setPin(p['seq'] as int),
                          _ => removePost(p['seq'] as int),
                        },
                      ),
                      itemBuilder: (_) => [
                        if (pinRevision != null &&
                            p['seq'] != pinnedPost?['seq'])
                          PopupMenuItem(
                            value: 'pin',
                            child: Text(tr('Закрепить', 'Pin post')),
                          ),
                        if (p['revision'] is int)
                          PopupMenuItem(
                            value: 'edit',
                            child: Text(tr('Изменить публикацию', 'Edit post')),
                          ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text(tr('Удалить публикацию', 'Delete post')),
                        ),
                      ],
                    )
                  : null,
            ),
          if (feedCursor != null)
            action(
              'Более ранние публикации',
              'Older posts',
              () => feed(more: true),
            ),
        ],
        if (room!['owner'] == true)
          action('Удалить канал', 'Delete channel', removeRoom),
      ],
    ],
  );
}
