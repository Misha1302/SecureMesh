import 'package:material_ui/material_ui.dart';

import 'display_name.dart';
import 'local_client.dart';

class ChannelComments extends StatefulWidget {
  const ChannelComments({
    super.key,
    required this.api,
    required this.path,
    required this.russian,
  });
  final DisplayNameApi api;
  final String path;
  final bool russian;
  @override
  State<ChannelComments> createState() => _ChannelCommentsState();
}

class _ChannelCommentsState extends State<ChannelComments> {
  final draft = TextEditingController();
  List<Map> rows = [];
  int? next;
  bool busy = true, failed = false;
  String? requestId, requestBody;
  String tr(String ru, String en) => widget.russian ? ru : en;

  @override
  void initState() {
    super.initState();
    run(() => load());
  }

  @override
  void dispose() {
    draft.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() operation) async {
    setState(() {
      busy = true;
      failed = false;
    });
    try {
      await operation();
    } catch (_) {
      if (mounted) {
        rows = [];
        next = null;
        failed = true;
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> load({bool older = false}) async {
    final page = await widget.api(
      older ? '${widget.path}?before=$next' : widget.path,
    );
    if (!mounted) return;
    final items = (page['items'] as List).cast<Map>();
    rows = older ? [...rows, ...items] : items;
    next = page['next'] as int?;
  }

  Future<void> send() async {
    final body = draft.text.trim();
    if (body.isEmpty) return;
    if (requestBody != body) {
      requestId = newUuid();
      requestBody = body;
    }
    await widget.api(widget.path, data: {'requestId': requestId, 'body': body});
    if (!mounted) return;
    draft.clear();
    requestBody = null;
    await load();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('Комментарии', 'Comments')),
    content: SizedBox(
      width: 420,
      child: ListView(
        shrinkWrap: true,
        children: [
          Text(
            tr(
              'Сервер и участники канала могут читать комментарии.',
              'The server and channel members can read comments.',
            ),
          ),
          if (failed)
            Text(
              tr(
                'Не удалось обновить комментарии.',
                'Could not update comments.',
              ),
            ),
          if (!busy && !failed && rows.isEmpty)
            Text(tr('Пока нет комментариев.', 'No comments yet.')),
          for (final row in rows)
            ListTile(
              title: SelectableText(row['body'] as String),
              subtitle: Text('@${row['username']}'),
              trailing: row['canDelete'] == true
                  ? IconButton(
                      tooltip: tr('Удалить комментарий', 'Delete comment'),
                      icon: const Icon(Icons.delete_outline),
                      onPressed: busy
                          ? null
                          : () => run(() async {
                              await widget.api(
                                '${widget.path}/${row['id']}',
                                method: 'DELETE',
                              );
                              if (mounted) await load();
                            }),
                    )
                  : null,
            ),
          if (next != null)
            TextButton(
              onPressed: busy ? null : () => run(() => load(older: true)),
              child: Text(tr('Предыдущие комментарии', 'Older comments')),
            ),
          TextButton(
            onPressed: busy ? null : () => run(() => load()),
            child: Text(tr('Обновить', 'Refresh')),
          ),
          TextField(
            controller: draft,
            enabled: !busy,
            maxLength: 512,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: tr('Комментарий', 'Comment'),
            ),
          ),
          FilledButton(
            onPressed: busy ? null : () => run(send),
            child: Text(tr('Отправить', 'Send')),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr('Закрыть', 'Close')),
      ),
    ],
  );
}
