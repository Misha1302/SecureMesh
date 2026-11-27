import 'package:material_ui/material_ui.dart';

import 'message_markup.dart';

class SavedMessages extends StatefulWidget {
  const SavedMessages({
    super.key,
    required this.tr,
    required this.read,
    required this.remove,
    required this.peerName,
  });
  final TranslateMarkup tr;
  final Future<Map<String, dynamic>> Function(int? before) read;
  final Future<void> Function(Map item) remove;
  final String Function(String group) peerName;
  @override
  State<SavedMessages> createState() => _SavedMessagesState();
}

class _SavedMessagesState extends State<SavedMessages> {
  final rows = <Map>[];
  int? before;
  bool busy = false, failed = false;
  @override
  void initState() {
    super.initState();
    fetch();
  }

  Future<void> fetch() async {
    if (busy) return;
    setState(() {
      busy = true;
      failed = false;
    });
    try {
      final result = await widget.read(before);
      if (!mounted) return;
      setState(() {
        rows.addAll((result['messages'] as List).cast<Map>());
        before = result['next'] as int?;
      });
    } catch (_) {
      if (mounted) setState(() => failed = true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> remove(Map entry) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.remove(entry);
      if (mounted) setState(() => rows.remove(entry));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.tr(
                'Не удалось убрать из избранного',
                'Could not remove saved message',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Избранное', 'Saved messages'))),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                tr('Сохранено на этом устройстве', 'Saved on this device'),
              ),
            ),
            if (busy) const LinearProgressIndicator(),
            if (rows.isEmpty && !busy && !failed)
              Expanded(
                child: Center(
                  child: Text(
                    tr(
                      'Сохранённых сообщений пока нет',
                      'No saved messages yet',
                    ),
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: rows.length,
                  itemBuilder: (ctx, i) {
                    final row = rows[i];
                    final peer = widget.peerName(row['group'] as String);
                    final file = row['attachmentName'] as String?;
                    return ListTile(
                      key: ValueKey((row['group'], row['id'], row['own'])),
                      title: Text(
                        row['own'] == true
                            ? tr('Вы · $peer', 'You · $peer')
                            : peer,
                      ),
                      subtitle: file == null
                          ? MessageMarkup(row['text'] as String, tr: tr)
                          : Text(file),
                      trailing: IconButton(
                        tooltip: tr(
                          'Убрать из избранного',
                          'Remove from saved messages',
                        ),
                        onPressed: busy ? null : () => remove(row),
                        icon: const Icon(Icons.bookmark_remove_outlined),
                      ),
                    );
                  },
                ),
              ),
            if (failed || before != null)
              TextButton(
                onPressed: busy ? null : fetch,
                child: Text(
                  failed
                      ? tr('Повторить загрузку', 'Retry loading')
                      : tr('Ещё', 'Load more'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
