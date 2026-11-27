import 'dart:async';
import 'dart:io';

/// Only the committed MLS application event can trigger a desktop notification.
bool isNewIncomingText(Map<String, dynamic> result, dynamic envelopeKind) {
  final event = result['event'];
  return envelopeKind == 1 &&
      result['duplicate'] != true &&
      event is Map &&
      event['own'] != true &&
      event['type'] == null &&
      event['text'] is String &&
      (event['text'] as String).isNotEmpty;
}

/// No caller may provide text, sender names, identifiers or notification actions.
class LinuxNotifications {
  LinuxNotifications({
    required this.allowed,
    required this.russian,
    required this.availability,
  });

  final bool Function() allowed, russian;
  final void Function(bool) availability;
  Timer? _pending;
  bool _sending = false;
  Stopwatch? _visible;
  int _generation = 0;

  Future<ProcessResult> _call(String method, List<String> args) =>
      Process.run('gdbus', [
        'call',
        '--session',
        '--timeout',
        '2',
        '--dest',
        'org.freedesktop.Notifications',
        '--object-path',
        '/org/freedesktop/Notifications',
        '--method',
        'org.freedesktop.Notifications.$method',
        ...args,
      ]);

  Future<void> probe() async {
    final generation = _generation;
    var available = false;
    try {
      available = (await _call('GetCapabilities', [])).exitCode == 0;
    } on ProcessException {
      available = false;
    }
    if (generation == _generation) availability(available);
  }

  void incoming() {
    if (!allowed() ||
        _sending ||
        _pending != null ||
        (_visible?.elapsed.inSeconds ?? 5) < 5) {
      return;
    }
    _pending = Timer(const Duration(seconds: 1), () {
      _pending = null;
      if (allowed()) unawaited(_show());
    });
  }

  Future<void> _show() async {
    _sending = true;
    final generation = _generation;
    var available = false;
    try {
      final result = await _call('Notify', [
        'SecureMesh',
        '0',
        '',
        'SecureMesh',
        russian() ? 'Новое сообщение' : 'New message',
        '[]',
        '{}',
        '5000',
      ]);
      available = result.exitCode == 0;
      if (available && generation == _generation) {
        _visible = Stopwatch()..start();
      }
    } on ProcessException {
      available = false;
    } finally {
      _sending = false;
    }
    if (generation == _generation) availability(available);
  }

  void cancel() {
    _generation++;
    _pending?.cancel();
    _pending = null;
    _visible = null;
  }
}
