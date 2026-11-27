import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'message_markup.dart';
import 'voice_note.dart';

class ConversationComposer extends StatelessWidget {
  const ConversationComposer({
    super.key,
    required this.editor,
    required this.onSend,
    required this.onFile,
    this.onPastePhoto,
    required this.onVoice,
    this.onVoiceHold,
    this.microphoneKey,
    required this.onVideo,
    required this.videoSupported,
    required this.tr,
  });
  final Widget editor;
  final VoidCallback? onSend, onFile, onVoice, onVideo, onPastePhoto;
  final Future<void> Function(ValueNotifier<VoiceHold>)? onVoiceHold;
  final Key? microphoneKey;
  final bool videoSupported;
  final TranslateMarkup tr;

  @override
  Widget build(BuildContext context) {
    final file = tr('Прикрепить файл (до 4 МиБ)', 'Attach file (up to 4 MiB)');
    final voice = tr('Записать голосовое сообщение', 'Record a voice note');
    final video = tr('Записать видеосообщение', 'Record video message');
    final send = tr('Поставить сообщение в очередь', 'Queue message');
    final media = [
      if (videoSupported) (video, Icons.videocam_outlined, onVideo),
      (file, Icons.attach_file, onFile),
      if (onPastePhoto != null)
        (
          tr('Вставить изображение', 'Paste image'),
          Icons.content_paste_outlined,
          onPastePhoto,
        ),
      (voice, Icons.mic_none, onVoice),
    ];
    Widget action(
      String label,
      IconData glyph,
      VoidCallback? callback, {
      bool filled = false,
    }) {
      final icon = Icon(glyph, semanticLabel: label);
      return filled
          ? IconButton.filled(tooltip: label, onPressed: callback, icon: icon)
          : IconButton(tooltip: label, onPressed: callback, icon: icon);
    }

    // Scaffold may consume the IME inset while resizing its body. Subscribe
    // to the original view metrics so the compact toolbar follows the IME.
    return MediaQuery.fromView(
      view: View.of(context),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 480;
          final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
          final buttons = [
            for (final (label, icon, callback) in media)
              if (icon == Icons.mic_none)
                _HoldMicButton(
                  key: microphoneKey,
                  label: label,
                  tap: callback,
                  hold: onVoiceHold,
                )
              else
                action(label, icon, callback),
          ];
          final sendButton = action(
            send,
            Icons.arrow_upward,
            onSend,
            filled: true,
          );
          final input = CallbackShortcuts(
            bindings: {
              if (onSend != null)
                for (final key in [
                  LogicalKeyboardKey.enter,
                  LogicalKeyboardKey.numpadEnter,
                ]) ...{
                  SingleActivator(key, control: true): onSend!,
                  SingleActivator(key, meta: true): onSend!,
                },
            },
            child: editor,
          );
          return Padding(
            padding: EdgeInsets.symmetric(
              horizontal: narrow ? 8 : 16,
              vertical: 4,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (!narrow) ...buttons,
                    if (narrow && keyboard)
                      PopupMenuButton<int>(
                        tooltip: tr('Вложения', 'Attachments'),
                        icon: const Icon(Icons.attach_file),
                        itemBuilder: (_) => [
                          for (var i = 0; i < media.length; i++)
                            PopupMenuItem(
                              value: i,
                              enabled: media[i].$3 != null,
                              child: Text(media[i].$1),
                            ),
                        ],
                        onSelected: (i) => media[i].$3?.call(),
                      ),
                    // Keep the IME connection when compact actions move into the input row.
                    Expanded(
                      key: const ValueKey('message-editor'),
                      child: input,
                    ),
                    if (narrow && keyboard) buttons.last,
                    const SizedBox(width: 4),
                    sendButton,
                  ],
                ),
                if (narrow && !keyboard) Row(children: buttons),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A tap (including semantic and keyboard activation) opens manual recording.
class _HoldMicButton extends StatefulWidget {
  const _HoldMicButton({
    super.key,
    required this.label,
    required this.tap,
    required this.hold,
  });
  final String label;
  final VoidCallback? tap;
  final Future<void> Function(ValueNotifier<VoiceHold>)? hold;
  @override
  State<_HoldMicButton> createState() => _HoldMicButtonState();
}

class _HoldMicButtonState extends State<_HoldMicButton> {
  ValueNotifier<VoiceHold>? active;
  Future<void> begin() async {
    final capture = widget.hold;
    if (capture == null || active != null) return;
    final hold = active = ValueNotifier(VoiceHold.recording);
    try {
      await capture(hold);
    } finally {
      active = null;
      hold.dispose();
    }
  }

  void move(Offset delta) {
    final hold = active;
    if (hold == null || hold.value != VoiceHold.recording) return;
    if (delta.dx <= -56 && delta.dx <= delta.dy) {
      hold.value = VoiceHold.cancelled;
    } else if (delta.dy <= -56) {
      hold.value = VoiceHold.locked;
    }
  }

  @override
  void dispose() {
    final hold = active;
    if (hold != null) hold.value = VoiceHold.cancelled;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: widget.label,
    triggerMode: TooltipTriggerMode.manual,
    child: Listener(
      onPointerCancel: (_) {
        final hold = active;
        if (hold?.value == VoiceHold.recording) {
          hold!.value = VoiceHold.cancelled;
        }
      },
      child: GestureDetector(
        excludeFromSemantics: true,
        onLongPressStart: widget.hold == null && active == null
            ? null
            : (_) => begin(),
        onLongPressMoveUpdate: (d) => move(d.offsetFromOrigin),
        onLongPressEnd: (_) {
          final hold = active;
          if (hold?.value == VoiceHold.recording) {
            hold!.value = VoiceHold.preview;
          }
        },
        child: IconButton(
          onPressed: widget.tap,
          icon: Icon(Icons.mic_none, semanticLabel: widget.label),
        ),
      ),
    ),
  );
}
