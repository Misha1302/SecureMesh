import 'package:material_ui/material_ui.dart';

import 'message_markup.dart';

typedef HistoryCursor = Map<String, dynamic>;

class EarlierHistory extends StatefulWidget {
  const EarlierHistory({
    super.key,
    required this.initial,
    this.title,
    required this.peer,
    required this.read,
    required this.tr,
  });
  final String? title;
  final HistoryCursor initial;
  final Future<Map<String, dynamic>> Function(HistoryCursor) read;
  final String peer;
  final TranslateMarkup tr;

  @override
  State<EarlierHistory> createState() => _EarlierHistoryState();
}

class _EarlierHistoryState extends State<EarlierHistory> {
  late final cursors = <HistoryCursor>[widget.initial];
  List<dynamic> rows = [];
  HistoryCursor? next;
  int page = 0;
  bool loading = true, failed = false;

  @override
  void initState() {
    super.initState();
    load(0);
  }

  Future<void> load(int index) async {
    setState(() {
      loading = true;
      failed = false;
      page = index;
    });
    try {
      final result = await widget.read(cursors[index]);
      if (!mounted) return;
      setState(() {
        rows = result['messages'] as List<dynamic>;
        next = result['next'] as HistoryCursor?;
        loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          rows = [];
          loading = false;
          failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title ?? tr('Более ранние сообщения', 'Earlier messages'),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (loading) const LinearProgressIndicator(),
            if (failed)
              TextButton.icon(
                onPressed: () => load(page),
                icon: const Icon(Icons.refresh),
                label: Text(tr('Повторить загрузку', 'Retry loading')),
              ),
            Expanded(
              child: loading || failed
                  ? const SizedBox()
                  : ListView.separated(
                      key: ValueKey(page),
                      padding: const EdgeInsets.all(12),
                      itemCount: rows.length,
                      separatorBuilder: (_, _) => const Divider(),
                      itemBuilder: (ctx, i) {
                        final entry = rows[i];
                        final ms = entry['localTimeMs'] as int?;
                        final dt = ms == null
                            ? null
                            : DateTime.fromMillisecondsSinceEpoch(ms);
                        final file = entry['attachmentName'] as String?;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry['own'] == true
                                  ? tr('Вы', 'You')
                                  : widget.peer,
                              style: Theme.of(ctx).textTheme.labelLarge,
                            ),
                            if (dt != null)
                              Text(
                                MaterialLocalizations.of(ctx)
                                    .formatCompactDate(dt),
                                style: Theme.of(ctx).textTheme.labelSmall,
                              ),
                            if (file != null)
                              Text(file)
                            else
                              MessageMarkup(entry['text'] as String, tr: tr),
                          ],
                        );
                      },
                    ),
            ),
            Wrap(
              children: [
                if (page > 0)
                  TextButton(
                    onPressed: loading ? null : () => load(page - 1),
                    child: Text(tr('К более новым', 'Newer')),
                  ),
                if (!failed && next != null)
                  TextButton(
                    onPressed: loading
                        ? null
                        : () {
                            if (page + 1 == cursors.length) cursors.add(next!);
                            load(page + 1);
                          },
                    child: Text(tr('Ещё раньше', 'Older')),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
