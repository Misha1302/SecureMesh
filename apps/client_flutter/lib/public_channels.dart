import 'package:material_ui/material_ui.dart';

import 'display_name.dart';
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
      post = TextEditingController();
  List<Map> rooms = [], posts = [];
  Map? room;
  String? directoryCursor, error;
  int? feedCursor;
  String activeQuery = '';
  bool mine = false, creating = false, busy = false;
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
    final result = await widget.api(url) as Map;
    if (!mounted) return;
    final page = (result['items'] as List).cast<Map>();
    posts = more ? [...posts, ...page] : page;
    feedCursor = result['next'] as int?;
  }

  Future<void> open(Map target) async {
    room = Map.of(target);
    posts = [];
    feedCursor = null;
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
    final key = '$handle\n$name';
    if (creationKey != key || createId == null) {
      createId = newUuid();
      creationKey = key;
    }
    final result = await widget.api(
      path,
      data: {'id': createId, 'slug': handle, 'title': name},
    ) as Map;
    if (!mounted) return;
    creating = false;
    createId = null;
    slug.clear();
    title.clear();
    await open({
      'id': result['id'],
      'slug': handle,
      'title': name,
      'owner': true,
      'subscribed': false,
    });
  }

  Future<void> subscribe() async {
    final add = room!['subscribed'] != true;
    await widget.api('$roomPath/subscription', method: add ? 'PUT' : 'DELETE');
    if (!mounted) return;
    room!['subscribed'] = add;
    if (add) {
      await feed();
    } else {
      posts = [];
      feedCursor = null;
    }
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

  Future<bool> confirm(String question) async =>
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
              child: Text(tr('Удалить', 'Delete')),
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

  Future<void> closeRoom() async {
    room = null;
    post.clear();
    posts = [];
    feedCursor = null;
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
                  tr('Публичные каналы', 'Public channels'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
        ],
      ),
      Text(
        tr(
          'Публикации видны серверу. Любой участник сервиса может найти канал и подписаться.',
          'The server can read posts. Anyone with an account can find and subscribe to a channel.',
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
        action('Создать канал', 'Create channel', create),
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
            subtitle: Text('@${c['slug']}'),
            leading: const Icon(Icons.campaign_outlined),
            onTap: busy ? null : () => run(() => open(c)),
          ),
        if (directoryCursor != null)
          action('Ещё каналы', 'More channels', () => catalog(more: true)),
      ] else ...[
        Text('@${room!['slug']}'),
        if (room!['owner'] == true) ...[
          TextField(
            controller: post,
            enabled: !busy,
            minLines: 1,
            maxLines: 5,
            maxLength: 2048,
            decoration: InputDecoration(
              labelText: tr('Публичная публикация', 'Public post'),
            ),
          ),
          action('Опубликовать', 'Publish', publish),
        ] else
          action(
            room!['subscribed'] == true ? 'Отписаться' : 'Подписаться',
            room!['subscribed'] == true ? 'Unsubscribe' : 'Subscribe',
            subscribe,
          ),
        if (room!['owner'] == true || room!['subscribed'] == true) ...[
          action('Обновить публикации', 'Refresh posts', feed),
          if (!busy && posts.isEmpty)
            Text(tr('Публикаций пока нет.', 'No posts yet.')),
          for (final p in posts)
            ListTile(
              title: SelectableText(p['body'] as String),
              subtitle: Text(
                MaterialLocalizations.of(context).formatMediumDate(
                  DateTime.parse(p['publishedAt'] as String).toLocal(),
                ),
              ),
              trailing: room!['owner'] == true
                  ? IconButton(
                      tooltip: tr('Удалить публикацию', 'Delete post'),
                      icon: const Icon(Icons.delete_outline),
                      onPressed: busy
                          ? null
                          : () => run(() => removePost(p['seq'] as int)),
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
