import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'message_markup.dart';

typedef _MessageKey = (String, String);
_MessageKey _key(dynamic message) =>
    (message['sender'] as String, message['id'] as String);

DateTime? _localTime(dynamic message) {
  final ms = message['localTimeMs'];
  if (ms is! int || ms <= 0 || ms > 8640000000000000) return null;
  return DateTime.fromMillisecondsSinceEpoch(ms);
}

class ConversationTimeline extends StatefulWidget {
  const ConversationTimeline({
    super.key,
    required this.messages,
    required this.scroll,
    required this.replyPreview,
    required this.attachment,
    required this.onReply,
    this.onOlder,
    this.onRetryQueue,
    this.onSave,
    this.onPin,
    this.pin,
    required this.tr,
  });

  final List<dynamic> messages;
  final ScrollController scroll;
  final String Function(String, String) replyPreview;
  final Widget Function(BuildContext, String, Map<String, dynamic>) attachment;
  final void Function(String, String)? onReply;
  final TranslateMarkup tr;
  final VoidCallback? onOlder;
  final VoidCallback? onRetryQueue;
  final Map<String, dynamic>? pin;
  final Future<void> Function(Map item, bool pinned)? onPin;
  final Future<void> Function(List<dynamic> rows)? onSave;

  @override
  State<ConversationTimeline> createState() => _ConversationTimelineState();
}

class _ConversationTimelineState extends State<ConversationTimeline> {
  final selected = <_MessageKey>{};
  final unreadMarker = GlobalKey();
  final pinnedMarker = GlobalKey();
  _MessageKey? firstUnread;
  bool away = false;
  bool movingToBottom = false;

  @override
  void didUpdateWidget(ConversationTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(widget.messages, oldWidget.messages)) return;
    if (selected.isNotEmpty || firstUnread != null) {
      final keys = widget.messages.map(_key).toSet();
      selected.retainAll(keys);
      if (!keys.contains(firstUnread)) firstUnread = null;
    }
    if (firstUnread != null || !away || oldWidget.messages.isEmpty) return;
    // Queued local messages have no server sequence and can remain at the end
    // as a new incoming message is inserted ahead of them.
    final previous = oldWidget.messages.map(_key).toSet();
    for (final entry in widget.messages) {
      final key = _key(entry);
      if (entry['own'] == false && !previous.contains(key)) {
        firstUnread = key;
        break;
      }
    }
  }

  void syncScroll() {
    if (!mounted || !widget.scroll.hasClients) return;
    final nowAway = widget.scroll.position.extentAfter >= 96;
    if (nowAway != away || (!nowAway && firstUnread != null)) {
      setState(() {
        away = nowAway;
        if (!away) firstUnread = null;
      });
    }
  }

  Future<void> goToBottom() async {
    if (!widget.scroll.hasClients || movingToBottom) return;
    movingToBottom = true;
    try {
      final scroll = widget.scroll;
      await scroll.animateTo(
        scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
      // A lazy list refines its estimate as variable-height rows are laid out.
      if (mounted && scroll.hasClients) {
        scroll.jumpTo(scroll.position.maxScrollExtent);
      }
    } finally {
      movingToBottom = false;
    }
  }

  String? copyable(dynamic m) {
    if (m['attachment'] != null) return null;
    return m['text'] as String?;
  }

  Future<void> copySelected() async {
    final text = widget.messages
        .where((m) => selected.contains(_key(m)))
        .map(copyable)
        .whereType<String>()
        .join('\n');
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) setState(selected.clear);
  }

  void toggle(_MessageKey key) => setState(() {
    if (!selected.remove(key)) selected.add(key);
  });

  Future<void> save(List<dynamic> rows) async {
    try {
      await widget.onSave!(rows);
      if (!mounted) return;
      setState(selected.clear);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.tr('В избранном на этом устройстве', 'Saved on this device'),
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.tr(
                'Не удалось сохранить в избранное',
                'Could not save message',
              ),
            ),
          ),
        );
      }
    }
  }

  Future<void> setPin(Map item, bool pin) async {
    try {
      await widget.onPin!(item, pin);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.tr(
                'Не удалось изменить закрепление',
                'Could not update pinned message',
              ),
            ),
          ),
        );
      }
    }
  }

  void openPinned(Map pin) {
    final anchor = pinnedMarker.currentContext;
    if (anchor != null) {
      Scrollable.ensureVisible(
        anchor,
        alignment: 0.35,
        duration: const Duration(milliseconds: 220),
      );
      return;
    }
    final tr = widget.tr;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Закреплено на устройстве', 'Pinned on this device')),
        content: SingleChildScrollView(
          child: pin['attachmentName'] is String
              ? Text(pin['attachmentName'] as String)
              : MessageMarkup(pin['text'] as String, tr: tr),
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

  Widget bubble(BuildContext ctx, int i) {
    final m = widget.messages[i];
    final own = m['own'] == true;
    final key = _key(m);
    final time = _localTime(m);
    final previous = i > 0 ? _localTime(widget.messages[i - 1]) : null;
    final next = i + 1 < widget.messages.length
        ? _localTime(widget.messages[i + 1])
        : null;
    final showDate = time != null && !DateUtils.isSameDay(previous, time);
    final prevSame =
        i > 0 &&
        widget.messages[i - 1]['sender'] == key.$1 &&
        DateUtils.isSameDay(previous, time) &&
        key != firstUnread;
    final nextSame =
        i + 1 < widget.messages.length &&
        widget.messages[i + 1]['sender'] == key.$1 &&
        DateUtils.isSameDay(next, time) &&
        _key(widget.messages[i + 1]) != firstUnread;
    final tr = widget.tr;
    final colors = Theme.of(ctx).colorScheme;
    final selectedHere = selected.contains(key);
    final (statusIcon, statusLabel) = _deliveryStatus(m['status'], tr);
    final text = copyable(m);
    // Give keyboard users an entry point at the first enabled menu action.
    var needsMenuFocus = true;
    bool firstMenuAction() {
      if (!needsMenuFocus) return false;
      needsMenuFocus = false;
      return true;
    }

    final upper = Radius.circular(prevSame ? 5 : 16);
    final lower = Radius.circular(nextSame ? 5 : 16);
    const round = Radius.circular(16);
    final content = Padding(
      padding: EdgeInsets.only(top: prevSame ? 2 : 8),
      child: Align(
        alignment: own ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: math.min(560, MediaQuery.sizeOf(ctx).width * .85),
          ),
          child: Material(
            color: selectedHere
                ? colors.secondaryContainer
                : own
                ? colors.primaryContainer
                : colors.surfaceContainerHigh,
            borderRadius: BorderRadius.only(
              topLeft: own ? round : upper,
              topRight: own ? upper : round,
              bottomLeft: own ? round : lower,
              bottomRight: own ? lower : round,
            ),
            child: Semantics(
              container: true,
              selected: selectedHere,
              label: own
                  ? '${tr('Ваше сообщение', 'Your message')}. $statusLabel'
                  : tr('Сообщение собеседника', 'Message from contact'),
              child: MenuAnchor(
                menuChildren: [
                  if (own)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(statusLabel),
                    ),
                  if (own &&
                      m['status'] == 'queued' &&
                      widget.onRetryQueue != null)
                    MenuItemButton(
                      autofocus: firstMenuAction(),
                      leadingIcon: const Icon(Icons.refresh),
                      onPressed: widget.onRetryQueue,
                      child: Text(
                        tr(
                          'Повторить отправку очереди',
                          'Retry sending queued messages',
                        ),
                      ),
                    ),
                  MenuItemButton(
                    autofocus: widget.onReply != null && firstMenuAction(),
                    leadingIcon: const Icon(Icons.reply),
                    onPressed: widget.onReply == null
                        ? null
                        : () => widget.onReply!(key.$2, key.$1),
                    child: Text(tr('Ответить', 'Reply')),
                  ),
                  if (text != null)
                    MenuItemButton(
                      autofocus: firstMenuAction(),
                      leadingIcon: const Icon(Icons.copy_outlined),
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: text)),
                      child: Text(tr('Скопировать текст', 'Copy text')),
                    ),
                  if (widget.onPin != null)
                    MenuItemButton(
                      autofocus: firstMenuAction(),
                      leadingIcon: const Icon(Icons.push_pin_outlined),
                      onPressed: () => setPin(m as Map, true),
                      child: Text(
                        tr('Закрепить на устройстве', 'Pin on this device'),
                      ),
                    ),
                  if (widget.onSave != null)
                    MenuItemButton(
                      autofocus: firstMenuAction(),
                      leadingIcon: const Icon(Icons.bookmark_add_outlined),
                      onPressed: () => save([m]),
                      child: Text(tr('В избранное', 'Save message')),
                    ),
                  MenuItemButton(
                    autofocus: firstMenuAction(),
                    leadingIcon: const Icon(Icons.check_circle_outline),
                    onPressed: () => toggle(key),
                    child: Text(
                      selectedHere
                          ? tr('Снять выделение', 'Deselect')
                          : tr('Выделить', 'Select'),
                    ),
                  ),
                ],
                builder: (context, controller, child) => GestureDetector(
                  onLongPress: controller.open,
                  onSecondaryTapUp: (details) =>
                      controller.open(position: details.localPosition),
                  child: Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 2, 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (m['replyTo'] case {
                                'id': String id,
                                'sender': String sender,
                              })
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Text(
                                    tr('В ответ на: ', 'In reply to: ') +
                                        widget.replyPreview(id, sender),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(ctx).textTheme.labelMedium
                                        ?.copyWith(color: colors.primary),
                                  ),
                                ),
                              if (m['attachment']
                                  case final Map<String, dynamic> data)
                                widget.attachment(ctx, key.$2, data)
                              else
                                MessageMarkup(text ?? '', tr: tr),
                              if (time != null)
                                Text(
                                  MaterialLocalizations.of(ctx).formatTimeOfDay(
                                    TimeOfDay.fromDateTime(time),
                                    alwaysUse24HourFormat:
                                        MediaQuery.alwaysUse24HourFormatOf(ctx),
                                  ),
                                  style: Theme.of(ctx).textTheme.labelSmall,
                                ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: tr('Действия сообщения', 'Message actions'),
                          onPressed: selected.isEmpty
                              ? controller.open
                              : () => toggle(key),
                          iconSize: 16,
                          icon: selectedHere
                              ? const Icon(Icons.check_circle)
                              : own
                              ? Icon(statusIcon)
                              : const Icon(Icons.more_horiz),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Column(
      key: ValueKey(key),
      children: [
        if (showDate)
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Text(
              tr(
                '${time.day.toString().padLeft(2, '0')}.${time.month.toString().padLeft(2, '0')}.${time.year}',
                MaterialLocalizations.of(ctx).formatMediumDate(time),
              ),
              style: Theme.of(ctx).textTheme.labelMedium,
            ),
          ),
        content,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    final boundary = firstUnread == null
        ? -1
        : widget.messages.indexWhere((m) => _key(m) == firstUnread);
    final canCopy =
        selected.isNotEmpty &&
        widget.messages.any(
          (m) => selected.contains(_key(m)) && copyable(m) != null,
        );
    final pin = widget.pin;
    final pinIndex = pin == null
        ? -1
        : widget.messages.indexWhere(
            (m) => m['id'] == pin['id'] && m['own'] == pin['own'],
          );
    Widget list(int start, int count) => SliverList.builder(
      itemCount: count,
      itemBuilder: (ctx, i) => bubble(ctx, start + i),
    );
    Widget rows(int start, int count) {
      if (pinIndex < start || pinIndex >= start + count) {
        return list(start, count);
      }
      // The pinned row has a render object even while off screen; navigation
      // never approximates an offset from variable message heights.
      return SliverMainAxisGroup(
        slivers: [
          if (pinIndex > start) list(start, pinIndex - start),
          SliverToBoxAdapter(
            child: KeyedSubtree(
              key: pinnedMarker,
              child: bubble(context, pinIndex),
            ),
          ),
          if (pinIndex + 1 < start + count)
            list(pinIndex + 1, start + count - pinIndex - 1),
        ],
      );
    }

    return Column(
      children: [
        if (pin != null && selected.isEmpty)
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: () => openPinned(pin),
                  icon: const Icon(Icons.push_pin_outlined),
                  label: Text(
                    tr('Закреплено на устройстве', 'Pinned on this device'),
                  ),
                ),
              ),
              if (widget.onPin != null)
                IconButton(
                  tooltip: tr('Открепить', 'Unpin message'),
                  onPressed: () => setPin(pin, false),
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
        if (selected.isNotEmpty)
          Row(
            children: [
              IconButton(
                tooltip: tr('Снять выделение', 'Clear selection'),
                onPressed: () => setState(selected.clear),
                icon: const Icon(Icons.close),
              ),
              Expanded(
                child: Text(
                  tr(
                    'Выбрано: ${selected.length}',
                    'Selected: ${selected.length}',
                  ),
                ),
              ),
              if (widget.onSave != null)
                IconButton(
                  tooltip: tr(
                    'Сохранить выделенные сообщения',
                    'Save selected messages',
                  ),
                  onPressed: () => save(
                    widget.messages
                        .where((m) => selected.contains(_key(m)))
                        .toList(),
                  ),
                  icon: const Icon(Icons.bookmark_add_outlined),
                ),
              if (canCopy)
                IconButton(
                  tooltip: tr(
                    'Скопировать текст выделенных сообщений',
                    'Copy selected text',
                  ),
                  onPressed: copySelected,
                  icon: const Icon(Icons.copy),
                ),
            ],
          ),
        Expanded(
          child: Stack(
            children: [
              NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification.depth == 0) {
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => syncScroll(),
                    );
                  }
                  return false;
                },
                child: CustomScrollView(
                  controller: widget.scroll,
                  slivers: [
                    if (widget.onOlder != null)
                      SliverToBoxAdapter(
                        child: Center(
                          child: TextButton.icon(
                            onPressed: widget.onOlder,
                            icon: const Icon(Icons.history),
                            label: Text(
                              tr('Более ранние сообщения', 'Earlier messages'),
                            ),
                          ),
                        ),
                      ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                      sliver: rows(
                        0,
                        boundary < 0 ? widget.messages.length : boundary,
                      ),
                    ),
                    if (boundary >= 0) ...[
                      SliverToBoxAdapter(
                        child: Center(
                          key: unreadMarker,
                          child: Text(tr('Новые сообщения', 'New messages')),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        sliver: rows(
                          boundary,
                          widget.messages.length - boundary,
                        ),
                      ),
                    ],
                    const SliverToBoxAdapter(child: SizedBox(height: 12)),
                  ],
                ),
              ),
              if (away)
                PositionedDirectional(
                  end: 8,
                  bottom: 4,
                  child: Material(
                    elevation: 1,
                    borderRadius: BorderRadius.circular(24),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (boundary >= 0)
                          TextButton(
                            onPressed: () {
                              final marker = unreadMarker.currentContext;
                              if (marker != null) {
                                Scrollable.ensureVisible(
                                  marker,
                                  duration: const Duration(milliseconds: 200),
                                );
                              }
                            },
                            child: Text(tr('К новым', 'First new')),
                          ),
                        IconButton(
                          tooltip: tr(
                            'К последнему сообщению',
                            'Latest message',
                          ),
                          onPressed: goToBottom,
                          icon: const Icon(Icons.keyboard_arrow_down),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

(IconData, String) _deliveryStatus(Object? status, TranslateMarkup tr) =>
    switch (status) {
      'queued' => (
        Icons.schedule,
        tr('В очереди на устройстве', 'Queued on this device'),
      ),
      'saved' => (Icons.check, tr('Принято сервером', 'Accepted by server')),
      'delivered' => (
        // The legacy name is derived from a server-supplied cursor. Only a
        // durable server acknowledgement is established for this message.
        Icons.check,
        tr(
          'Принято сервером. Получение устройством не подтверждено',
          'Accepted by server. Device delivery is unconfirmed',
        ),
      ),
      _ => (Icons.more_horiz, tr('Статус неизвестен', 'Status unknown')),
    };
