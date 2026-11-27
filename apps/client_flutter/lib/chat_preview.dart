import 'package:material_ui/material_ui.dart';

/// A local, decrypted list summary. It never leaves the open profile.
class ChatPreview {
  const ChatPreview(this.text, this.own, this.timeMs, this.unread);

  final String text;
  final bool own;
  final int timeMs;
  final int unread;

  static ChatPreview? read(Object? value) {
    if (value is! Map ||
        value['text'] is! String ||
        value['own'] is! bool ||
        value['localTimeMs'] is! int ||
        value['unread'] is! int) {
      return null;
    }
    return ChatPreview(
      value['text'] as String,
      value['own'] as bool,
      value['localTimeMs'] as int,
      value['unread'] as int,
    );
  }

  String summary(bool russian) {
    final content = text.contains('||')
        ? (russian ? 'Сообщение со спойлером' : 'Message with a spoiler')
        : text
              .replaceAll(
                RegExp(
                  r'[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u2028-\u202e\u2066-\u2069]+',
                ),
                ' ',
              )
              .trim();
    final label = content.isEmpty
        ? (russian ? 'Сообщение' : 'Message')
        : content;
    return own ? '${russian ? 'Вы' : 'You'}: $label' : label;
  }

  String? timeLabel(BuildContext context) {
    if (timeMs <= 0 || timeMs > 8640000000000000) return null;
    final time = DateTime.fromMillisecondsSinceEpoch(timeMs);
    if (DateUtils.isSameDay(time, DateTime.now())) {
      return TimeOfDay.fromDateTime(time).format(context);
    }
    return MaterialLocalizations.of(context).formatShortDate(time);
  }
}
