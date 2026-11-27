import 'package:flutter/widgets.dart';

typedef DraftCommand = Future<Map<String, dynamic>> Function(
  String operation,
  Map<String, dynamic> args,
);

/// A single unlocked profile owns this queue, including its captured native store.
/// A conversation change invalidates any prior read before touching the controller.
class ConversationDrafts {
  ConversationDrafts(this.controller, this.command, this.onWriteFailure) {
    controller.addListener(_edited);
  }

  final TextEditingController controller;
  final DraftCommand command;
  final VoidCallback onWriteFailure;
  Future<void> _tail = Future.value();
  String? _group;
  String _last = '';
  int _generation = 0;
  int _edits = 0;
  bool _closed = false;
  bool _ready = false;

  bool readyFor(String? group) =>
      !_closed && _ready && group != null && _group == group;

  Future<T> _ordered<T>(Future<T> Function() work) {
    final next = _tail.then((_) => work());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  void _replace(String text) {
    _last = text;
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<void> select(String? group) async {
    final epoch = ++_generation;
    _group = group;
    _ready = false;
    _replace('');
    if (group == null || _closed) return;
    final result = await _ordered(() => command('draft_get', {'group': group}));
    if (_closed || _generation != epoch) return;
    _replace(result['text'] as String);
    _ready = true;
  }

  void _edited() {
    final group = _group;
    final text = controller.text;
    if (!readyFor(group) || _last == text) return;
    _last = text;
    _edits++;
    final epoch = _generation;
    _ordered(() => command('draft_put', {'group': group, 'text': text}))
        .then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {
            if (!_closed && _generation == epoch) onWriteFailure();
          },
        );
  }

  Future<void> enqueue(String group, String id) async {
    if (!readyFor(group)) throw StateError('Draft is unavailable');
    final epoch = _generation;
    final edits = _edits;
    final draft = controller.text;
    await _ordered(
      () => command('queue', {
        'group': group,
        'id': id,
        'text': draft.trim(),
        'submittedDraft': draft,
      }),
    );
    if (!_closed && epoch == _generation && _edits == edits) _replace('');
  }

  Future<void> close() {
    if (!_closed) {
      _closed = true;
      controller.removeListener(_edited);
      _replace('');
    }
    return _tail;
  }
}
