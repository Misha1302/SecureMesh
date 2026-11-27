import 'dart:async';
import 'dart:io';

abstract interface class NativeNotificationBridge {
  Future<bool> available();
  Future<bool> show(bool russian);
  Future<void> clear();
}

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
    this.bridge,
    this.allowsGroup,
    required this.allowed,
    required this.russian,
    required this.availability,
  });

  final NativeNotificationBridge? bridge;
  final bool Function(String group)? allowsGroup;
  final _groups = <String?>{};
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
      available = bridge != null
          ? await bridge!.available()
          : (await _call('GetCapabilities', [])).exitCode == 0;
    } on Exception {
      available = false;
    }
    if (generation == _generation) availability(available);
  }

  bool _allows(String? group) =>
      allowsGroup == null || (group != null && allowsGroup!(group));

  void incoming([String? group]) {
    if (!allowed() ||
        _sending ||
        !_allows(group) ||
        (_visible?.elapsed.inSeconds ?? 5) < 5) {
      return;
    }
    _groups.add(group);
    if (_pending != null) return;
    _pending = Timer(const Duration(seconds: 1), () {
      _pending = null;
      final eligible = allowed() && _groups.any(_allows);
      _groups.clear();
      if (eligible) unawaited(_show());
    });
  }

  Future<void> _show() async {
    _sending = true;
    final generation = _generation;
    var available = false;
    try {
      if (bridge != null) {
        available = await bridge!.show(russian());
      } else {
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
      }
      if (available && generation == _generation) {
        _visible = Stopwatch()..start();
      }
    } on Exception {
      available = false;
    } finally {
      _sending = false;
    }
    if (generation == _generation) availability(available);
  }

  void cancel() {
    unawaited(bridge?.clear().catchError((_) {}));
    _generation++;
    _groups.clear();
    _pending?.cancel();
    _pending = null;
    _visible = null;
  }
}
