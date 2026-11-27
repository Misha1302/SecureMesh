import 'package:material_ui/material_ui.dart';

import 'message_markup.dart';

class HistorySearch extends StatefulWidget {
  const HistorySearch({
    super.key,
    required this.tr,
    required this.search,
    required this.peerName,
  });

  final TranslateMarkup tr;
  final String peerName;
  final Future<Map<String, dynamic>> Function(String query) search;

  @override
  State<HistorySearch> createState() => _HistorySearchState();
}

class _HistorySearchState extends State<HistorySearch> {
  final query = TextEditingController();
  int revision = 0;
  bool loading = false, failed = false, more = false;
  List<dynamic>? messages;

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  void reset() => setState(() {
    revision++;
    messages = null;
    failed = loading = more = false;
  });

  Future<void> submit() async {
    final text = query.text.trim();
    if (loading || text.isEmpty) return;
    final current = ++revision;
    setState(() {
      loading = true;
      failed = more = false;
      messages = null;
    });
    try {
      final result = await widget.search(text);
      if (!mounted || current != revision) return;
      setState(() {
        messages = result['messages'] as List<dynamic>;
        more = result['more'] == true;
        loading = false;
      });
    } catch (_) {
      if (mounted && current == revision) {
        setState(() {
          failed = true;
          loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Поиск в переписке', 'Search conversation')),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                autofocus: true,
                controller: query,
                maxLength: 128,
                textInputAction: TextInputAction.search,
                onChanged: (_) => reset(),
                onSubmitted: (_) => submit(),
                decoration: InputDecoration(
                  labelText: tr('Текст сообщения', 'Message text'),
                  counterText: '',
                  suffixIcon: IconButton(
                    tooltip: tr('Найти', 'Search'),
                    onPressed: loading || query.text.trim().isEmpty
                        ? null
                        : submit,
                    icon: const Icon(Icons.search),
                  ),
                ),
              ),
            ),
            if (loading) const LinearProgressIndicator(),
            if (failed)
              Text(
                tr(
                  'Поиск не выполнен. Повторите попытку.',
                  'Search failed. Try again.',
                ),
              ),
            if (messages?.isEmpty == true)
              Text(tr('Сообщений не найдено', 'No messages found')),
            if (more)
              Text(
                tr(
                  'Показаны 50 совпадений. Уточните запрос.',
                  'Showing 50 matches. Refine your search.',
                ),
              ),
            if (messages != null)
              Expanded(
                child: ListView.builder(
                  itemCount: messages!.length,
                  itemBuilder: (context, index) {
                    final result = messages![index];
                    final hidden = result['spoiler'] == true;
                    final text = result['text'] as String;
                    return ListTile(
                      title: Text(
                        result['own'] == true
                            ? tr('Вы', 'You')
                            : widget.peerName,
                      ),
                      subtitle: Text(
                        hidden
                            ? tr(
                                'Сообщение со спойлером',
                                'Message with a spoiler',
                              )
                            : result['snippet'] as String,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (ctx) => _SearchMessage(
                          text: text,
                          spoiler: hidden,
                          truncated: result['truncated'] == true,
                          tr: tr,
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SearchMessage extends StatefulWidget {
  const _SearchMessage({
    required this.text,
    required this.spoiler,
    required this.truncated,
    required this.tr,
  });
  final String text;
  final bool spoiler, truncated;
  final TranslateMarkup tr;

  @override
  State<_SearchMessage> createState() => _SearchMessageState();
}

class _SearchMessageState extends State<_SearchMessage> {
  bool reveal = false;

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    return AlertDialog(
      title: Text(tr('Сообщение', 'Message')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.spoiler && !reveal)
              TextButton(
                onPressed: () => setState(() => reveal = true),
                child: Text(
                  tr('Показать скрытое сообщение', 'Reveal hidden message'),
                ),
              )
            else
              SelectableText(widget.text),
            if (widget.truncated)
              Text(
                tr(
                  'Показано начало сообщения.',
                  'Showing the beginning of this message.',
                ),
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
}
