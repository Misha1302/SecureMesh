import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

typedef TranslateMarkup = String Function(String russian, String english);

enum MessageFormat {
  bold('Жирный', 'Bold', '**', '**'),
  italic('Курсив', 'Italic', '*', '*'),
  underline('Подчеркнуть', 'Underline', '__', '__'),
  strike('Зачеркнуть', 'Strikethrough', '~~', '~~'),
  spoiler('Спойлер', 'Spoiler', '||', '||'),
  code('Моноширинный', 'Inline code', '`', '`'),
  block('Блок кода', 'Code block', '```\n', '\n```'),
  quote('Цитата', 'Quote', '> ', ''),
  bullets('Список', 'Bullet list', '- ', ''),
  numbers('Нумерация', 'Numbered list', '1. ', ''),
  link('Ссылка', 'Link', '[', '](https://)');

  const MessageFormat(this.ru, this.en, this.open, this.close);
  final String ru, en, open, close;
}

void formatMessage(TextEditingController controller, MessageFormat format) {
  final value = controller.value;
  final selection = value.selection;
  final start = selection.isValid ? selection.start : value.text.length;
  final end = selection.isValid ? selection.end : value.text.length;
  final selected = value.text.substring(start, end);
  String content = selected;
  String prefix = format.open;
  if (format.close.isEmpty) {
    var index = 1;
    content = selected
        .split('\n')
        .map((line) {
          final marker = format == MessageFormat.numbers
              ? '${index++}. '
              : prefix;
          return marker + line;
        })
        .join('\n');
    prefix = '';
  }
  final block = format.close.isEmpty || format == MessageFormat.block;
  if (block && start > 0 && value.text[start - 1] != '\n') prefix = '\n$prefix';
  var suffix = format.close;
  if (block && end < value.text.length && value.text[end] != '\n') {
    suffix += '\n';
  }
  final text = value.text.replaceRange(start, end, prefix + content + suffix);
  if (text.characters.length > 4000) return;
  final offset = start + prefix.length;
  controller.value = TextEditingValue(
    text: text,
    selection: TextSelection(
      baseOffset: selected.isEmpty && format.close.isEmpty
          ? offset + content.length
          : offset,
      extentOffset: offset + content.length,
    ),
  );
}

final _unsafeLinkText = RegExp(
  r'[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u2028-\u202e\u2066-\u2069]',
);
bool _validLinkLabel(String label) =>
    label.trim().isNotEmpty &&
    label.length <= 256 &&
    !label.contains(']') &&
    !_unsafeLinkText.hasMatch(label);

bool _validAddress(String address) {
  if (address.length > 2048 ||
      _unsafeLinkText.hasMatch(address) ||
      RegExp(r'[\s\\()]').hasMatch(address)) {
    return false;
  }
  final uri = Uri.tryParse(address);
  return uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}

Future<void> _insertLink(
  BuildContext context,
  TextEditingController controller,
  TranslateMarkup tr,
) async {
  final source = controller.value;
  final selection = source.selection.isValid
      ? source.selection
      : TextSelection.collapsed(offset: source.text.length);
  var label = selection.textInside(source.text);
  var address = _validAddress(label) ? label : '';
  final form = GlobalKey<FormState>();
  final updated = await showDialog<TextEditingValue>(
    context: context,
    builder: (dialog) {
      String target() =>
          address.trim().replaceAll('(', '%28').replaceAll(')', '%29');
      String replacement() => '[${label.trim()}](${target()})';
      String message() => source.text.replaceRange(
        selection.start,
        selection.end,
        replacement(),
      );
      void insert() {
        if (form.currentState!.validate()) {
          Navigator.pop(
            dialog,
            TextEditingValue(
              text: message(),
              selection: TextSelection.collapsed(
                offset: selection.start + replacement().length,
              ),
            ),
          );
        }
      }

      return AlertDialog(
        title: Text(tr('Вставить ссылку', 'Insert link')),
        scrollable: true,
        content: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                initialValue: label,
                autofocus: label.isEmpty,
                decoration: InputDecoration(
                  labelText: tr('Текст ссылки', 'Link text'),
                ),
                textInputAction: TextInputAction.next,
                onChanged: (v) => label = v,
                validator: (_) => _validLinkLabel(label.trim())
                    ? null
                    : tr(
                        'Введите подпись до 256 символов без ] и переносов.',
                        'Enter a label of up to 256 characters without ] or line breaks.',
                      ),
              ),
              TextFormField(
                initialValue: address,
                autofocus: label.isNotEmpty,
                keyboardType: TextInputType.url,
                textDirection: TextDirection.ltr,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: tr('Адрес', 'Address'),
                  hintText: 'https://',
                ),
                onChanged: (v) => address = v,
                onFieldSubmitted: (_) => insert(),
                validator: (_) {
                  if (!_validAddress(target())) {
                    return tr(
                      'Укажите адрес HTTP или HTTPS без данных для входа.',
                      'Enter an HTTP or HTTPS address without credentials.',
                    );
                  }
                  return message().characters.length <= 4000
                      ? null
                      : tr(
                          'Сообщение превышает 4000 символов.',
                          'Message exceeds 4000 characters.',
                        );
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(tr('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: insert,
            child: Text(tr('Вставить', 'Insert')),
          ),
        ],
      );
    },
  );
  if (context.mounted && updated != null && controller.text == source.text) {
    controller.value = updated;
  }
}

class MessageComposer extends StatelessWidget {
  const MessageComposer({
    super.key,
    required this.controller,
    required this.tr,
    required this.onSubmitted,
  });
  final TextEditingController controller;
  final TranslateMarkup tr;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    void apply(MessageFormat format) {
      if (format == MessageFormat.link) {
        _insertLink(context, controller, tr);
      } else {
        formatMessage(controller, format);
      }
    }

    return CallbackShortcuts(
      bindings: {
        for (final meta in [false, true])
          for (final entry in {
            LogicalKeyboardKey.keyB: MessageFormat.bold,
            LogicalKeyboardKey.keyI: MessageFormat.italic,
            LogicalKeyboardKey.keyU: MessageFormat.underline,
            LogicalKeyboardKey.keyK: MessageFormat.link,
          }.entries)
            SingleActivator(entry.key, control: !meta, meta: meta): () =>
                apply(entry.value),
        for (final meta in [false, true])
          SingleActivator(
            LogicalKeyboardKey.keyX,
            control: !meta,
            meta: meta,
            shift: true,
          ): () =>
              apply(MessageFormat.strike),
      },
      child: TextField(
        controller: controller,
        minLines: 1,
        maxLines: 4,
        maxLength: 4000,
        onSubmitted: onSubmitted,
        contextMenuBuilder: (context, state) =>
            AdaptiveTextSelectionToolbar.buttonItems(
              anchors: state.contextMenuAnchors,
              buttonItems: [
                ...state.contextMenuButtonItems,
                for (final format in MessageFormat.values)
                  ContextMenuButtonItem(
                    label: tr(format.ru, format.en),
                    onPressed: () {
                      state.hideToolbar();
                      apply(format);
                    },
                  ),
              ],
            ),
        decoration: InputDecoration(
          labelText: tr('Сообщение', 'Message'),
          border: const OutlineInputBorder(),
          counterText: '',
          suffixIcon: PopupMenuButton<MessageFormat>(
            tooltip: tr('Форматирование', 'Formatting'),
            icon: const Icon(Icons.text_format),
            onSelected: apply,
            itemBuilder: (_) => [
              for (final format in MessageFormat.values)
                PopupMenuItem(
                  value: format,
                  child: Text(tr(format.ru, format.en)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// Only text widgets are constructed. Links require an explicit copy action.
// No browser, HTML interpreter, URL launcher, image provider or HTTP client.
class MessageMarkup extends StatelessWidget {
  const MessageMarkup(this.text, {super.key, required this.tr});
  final String text;
  final TranslateMarkup tr;
  static final _inline = RegExp(
    r'\\([\\*_~|`\[\]])|\*\*([^*\n]+)\*\*|__([^_\n]+)__|~~([^~\n]+)~~|\|\|([^|\n]+)\|\||`([^`\n]+)`|\*([^*\n]+)\*|_([^_\n]+)_|\[([^\]\n]{1,256})\]\((https?://[^\s()]{1,2048})\)',
    caseSensitive: false,
  );
  static final _keywords = RegExp(
    r'\b(class|def|fn|function|if|else|for|while|let|var|final|const|int|bool|return|true|false|null|None|import|from|void|async|await|pub|use|struct)\b',
  );

  List<InlineSpan> _inlineSpans(
    BuildContext context,
    String content,
    int depth,
  ) {
    if (depth > 8) return [TextSpan(text: content)];
    final spans = <InlineSpan>[];
    var end = 0;
    for (final m in _inline.allMatches(content)) {
      if (end < m.start) {
        spans.add(TextSpan(text: content.substring(end, m.start)));
      }
      if (m[5] != null) {
        spans.add(
          WidgetSpan(
            child: _Spoiler(
              key: ValueKey((text, m.start, m[5])),
              content: m[5]!,
              tr: tr,
            ),
          ),
        );
      } else if (m[9] != null) {
        if (!_validAddress(m[10]!) || !_validLinkLabel(m[9]!)) {
          spans.add(TextSpan(text: m[0]));
        } else {
          spans.add(
            WidgetSpan(
              child: ActionChip(
                label: Text(m[9]!),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text(tr('Адрес ссылки', 'Link address')),
                    content: SelectableText(m[10]!),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(tr('Закрыть', 'Close')),
                      ),
                      TextButton(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: m[10]!));
                          Navigator.pop(ctx);
                        },
                        child: Text(tr('Скопировать', 'Copy')),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
      } else {
        final nested = m[2] ?? m[3] ?? m[4] ?? m[7] ?? m[8];
        spans.add(
          TextSpan(
            text: m[1] ?? m[6],
            children: nested == null
                ? null
                : _inlineSpans(context, nested, depth + 1),
            style: TextStyle(
              fontWeight: m[2] == null ? null : FontWeight.bold,
              fontStyle: m[7] != null || m[8] != null ? FontStyle.italic : null,
              decoration: m[3] != null
                  ? TextDecoration.underline
                  : m[4] != null
                  ? TextDecoration.lineThrough
                  : null,
              fontFamily: m[6] == null ? null : 'monospace',
            ),
          ),
        );
      }
      end = m.end;
    }
    spans.add(TextSpan(text: content.substring(end)));
    return spans;
  }

  Widget _line(BuildContext context, String line) {
    final colors = Theme.of(context).colorScheme;
    var content = line;
    var quote = false;
    if (content.startsWith('> ')) {
      quote = true;
      content = content.substring(2);
    } else if (content.startsWith('- ') || content.startsWith('* ')) {
      content = '• ${content.substring(2)}';
    }
    final body = Text.rich(
      TextSpan(children: _inlineSpans(context, content, 0)),
    );
    if (!quote) return body;
    return Container(
      decoration: BoxDecoration(
        border: BorderDirectional(
          start: BorderSide(color: colors.primary, width: 3),
        ),
      ),
      padding: const EdgeInsetsDirectional.only(start: 8),
      child: body,
    );
  }

  Widget _code(BuildContext context, String source, String language) {
    final colors = Theme.of(context).colorScheme;
    final spans = <TextSpan>[];
    var end = 0;
    if (const {
      'dart',
      'rs',
      'rust',
      'py',
      'python',
      'js',
      'javascript',
      'ts',
      'typescript',
      'c',
      'cpp',
      'java',
      'kotlin',
    }.contains(language)) {
      for (final m in _keywords.allMatches(source)) {
        spans.add(TextSpan(text: source.substring(end, m.start)));
        spans.add(
          TextSpan(
            text: m[0],
            style: TextStyle(
              color: colors.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
        end = m.end;
      }
    }
    spans.add(TextSpan(text: source.substring(end)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconButton(
          tooltip: tr('Скопировать код', 'Copy code'),
          onPressed: () => Clipboard.setData(ClipboardData(text: source)),
          icon: const Icon(Icons.copy),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text.rich(
            TextSpan(children: spans),
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (text.length > 16000) return SelectableText(text);
    final lines = text.split('\n');
    // A pathological message must not allocate a widget per newline.
    if (lines.length > 200) return SelectableText(text);
    final blocks = <Widget>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.startsWith('```')) {
        final language = line.substring(3).trim().toLowerCase();
        final start = ++i;
        while (i < lines.length && lines[i].trim() != '```') {
          i++;
        }
        blocks.add(
          _code(context, lines.sublist(start, i).join('\n'), language),
        );
      } else {
        blocks.add(_line(context, line));
      }
    }
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: blocks,
      ),
    );
  }
}

class _Spoiler extends StatefulWidget {
  const _Spoiler({super.key, required this.content, required this.tr});
  final String content;
  final TranslateMarkup tr;
  @override
  State<_Spoiler> createState() => _SpoilerState();
}

class _SpoilerState extends State<_Spoiler> {
  bool revealed = false;
  @override
  Widget build(BuildContext context) => ActionChip(
    label: Text(
      revealed
          ? widget.content
          : widget.tr('Показать спойлер', 'Reveal spoiler'),
    ),
    onPressed: () => setState(() => revealed = !revealed),
  );
}
