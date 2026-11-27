import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'attachment_transfer.dart';
import 'conversation_drafts.dart';
import 'identity_comparison.dart';

enum MediaSection {
  photo('Фото', 'Photos', Icons.photo_outlined),
  video('Видео', 'Videos', Icons.videocam_outlined),
  file('Файлы', 'Files', Icons.description_outlined),
  links('Ссылки', 'Links', Icons.link),
  audio('Аудио', 'Audio', Icons.audiotrack_outlined),
  voice('Голосовые', 'Voice notes', Icons.mic_none);

  const MediaSection(this.ru, this.en, this.icon);
  final String ru, en;
  final IconData icon;
}

final _links = RegExp(
  r'''https?://[^\s<>"'\x00-\x1f]+''',
  caseSensitive: false,
);
final _controls = RegExp(r'[\u061c\u200e\u200f\u2028-\u202e\u2066-\u2069]');

Iterable<String> messageLinks(String text) sync* {
  if (text.contains('||')) return;
  final seen = <String>{};
  for (final match in _links.allMatches(text)) {
    var candidate = match.group(0)!.replaceFirst(RegExp(r'[.,!?:;]+$'), '');
    for (final pair in [('(', ')'), ('[', ']')]) {
      while (candidate.endsWith(pair.$2) &&
          pair.$2.allMatches(candidate).length >
              pair.$1.allMatches(candidate).length) {
        candidate = candidate.substring(0, candidate.length - 1);
      }
    }
    if (candidate.length > 2048 || _controls.hasMatch(candidate)) continue;
    final uri = Uri.tryParse(candidate);
    if (uri != null &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        seen.add(candidate)) {
      yield candidate;
    }
  }
}

class ConversationMedia extends StatefulWidget {
  const ConversationMedia({
    super.key,
    required this.group,
    required this.tr,
    required this.crypto,
    required this.canDownload,
    this.createTransfer,
  });
  final String group;
  final IdentityTranslation tr;
  final DraftCommand crypto;
  final Future<bool> Function() canDownload;
  final PrivateAttachments Function(String group)? createTransfer;

  @override
  State<ConversationMedia> createState() => _ConversationMediaState();
}

class _ConversationMediaState extends State<ConversationMedia> {
  var section = MediaSection.photo;
  var rows = <Map>[];
  Map? next;
  bool loading = false, failed = false, saving = false;
  String? saveNotice;
  int request = 0;
  PrivateAttachments? transfer;

  @override
  void initState() {
    super.initState();
    load(reset: true);
  }

  Future<void> load({required bool reset}) async {
    final generation = ++request;
    setState(() {
      if (reset) {
        rows = [];
        next = null;
        saveNotice = null;
      }
      failed = false;
      loading = true;
    });
    try {
      final result = await widget.crypto('conversation_media', {
        'group': widget.group,
        'category': section.name,
        'cursor': next,
      });
      if (!mounted || generation != request) return;
      final items = (result['items'] as List).whereType<Map>();
      final display = section == MediaSection.links
          ? [
              for (final item in items)
                for (final link in messageLinks(item['body'] as String))
                  {'link': link},
            ]
          : items;
      setState(() {
        rows.addAll(display);
        next = result['next'] as Map?;
      });
    } catch (_) {
      if (mounted && generation == request) setState(() => failed = true);
    } finally {
      if (mounted && generation == request) setState(() => loading = false);
    }
  }

  Future<void> save(Map item) async {
    final create = widget.createTransfer;
    if (saving || create == null) return;
    final tr = widget.tr;
    setState(() {
      saving = true;
      saveNotice = null;
    });
    try {
      if (!await widget.canDownload()) {
        if (mounted) {
          setState(
            () => saveNotice = tr(
              'Сохранение заблокировано. Проверьте личность собеседника.',
              'Saving blocked. Verify this contact’s identity.',
            ),
          );
        }
        return;
      }
      if (!mounted) return;
      final current = transfer ??= create(widget.group);
      await current.download(
        item['id'] as String,
        Map<String, dynamic>.from(item['attachment'] as Map),
        (name, bytes) =>
            mounted ? exportAttachment(name, bytes) : Future.value(false),
      );
      if (mounted) {
        setState(
          () => saveNotice = switch (current.status) {
            'saved' => tr('Файл сохранён', 'File saved'),
            'paused' => tr(
              'Сначала доставим сообщения. Повторите сохранение позже.',
              'Messages are being delivered. Try saving again shortly.',
            ),
            null => null,
            _ => tr(
              'Не удалось сохранить файл. Повторите попытку.',
              'Could not save the file. Try again.',
            ),
          },
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => saveNotice = tr(
            'Не удалось сохранить файл. Повторите попытку.',
            'Could not save the file. Try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  void dispose() {
    transfer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Медиа диалога', 'Shared media'))),
      body: SafeArea(
        child: Column(
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    for (final filter in MediaSection.values)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 6),
                        child: ChoiceChip(
                          label: Text(tr(filter.ru, filter.en)),
                          selected: section == filter,
                          onSelected: saving
                              ? null
                              : (_) {
                                  if (section == filter) return;
                                  section = filter;
                                  load(reset: true);
                                },
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (loading || saving) const LinearProgressIndicator(),
            if (saveNotice != null)
              Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(saveNotice!),
                ),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: rows.length + 1,
                itemBuilder: (context, index) {
                  if (index == rows.length) {
                    if (!loading && (failed || next != null)) {
                      return Center(
                        child: TextButton(
                          onPressed: () => load(reset: false),
                          child: Text(
                            failed
                                ? tr(
                                    'Не удалось загрузить. Повторить',
                                    'Loading failed. Retry',
                                  )
                                : tr('Показать ещё', 'Show more'),
                          ),
                        ),
                      );
                    }
                    if (!loading && rows.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          tr(
                            'На этом устройстве пока ничего нет в этом разделе.',
                            'No items in this section on this device.',
                          ),
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  }
                  final item = rows[index];
                  if (item['link'] case final String link) {
                    return ListTile(
                      leading: const Icon(Icons.link),
                      title: SelectableText(link),
                      trailing: IconButton(
                        tooltip: tr('Копировать ссылку', 'Copy link'),
                        icon: const Icon(Icons.copy),
                        onPressed: () =>
                            Clipboard.setData(ClipboardData(text: link)),
                      ),
                    );
                  }
                  final meta = item['attachment'] as Map;
                  final name = attachmentName(meta['name'] as String);
                  return ListTile(
                    leading: Icon(section.icon),
                    title: Text(name),
                    subtitle: Text(
                      '${((meta['size'] as int) / 1024).ceil()} KiB',
                    ),
                    trailing: widget.createTransfer == null
                        ? null
                        : IconButton(
                            tooltip: tr('Сохранить $name', 'Save $name'),
                            icon: const Icon(Icons.download_outlined),
                            onPressed: saving ? null : () => save(item),
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
