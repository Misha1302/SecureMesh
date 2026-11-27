import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'transport.dart';

typedef SessionPolicyRequest = Future<dynamic> Function(
  String route, {
  Map<String, dynamic>? data,
  String? method,
  String? notFoundCode,
});

class SessionInactivity {
  SessionInactivity(this._request, {Duration Function()? elapsed})
    : _elapsed = elapsed ?? _monotonicClock();

  static const _policyRoute = '/v1/auth/session/inactivity';
  static const _activityRoute = '/v1/auth/session/activity';
  static const _choices = ['1', '3', '7', '14', '30', '90', 'never'];
  static const _interval = Duration(minutes: 1);

  final SessionPolicyRequest _request;
  final Duration Function() _elapsed;
  Duration? _lastAttempt;
  bool _reporting = false;
  bool _unsupported = false;

  static Duration Function() _monotonicClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  Future<String?> load() => _policyRequest();

  Future<String?> save(String timeout) =>
      _policyRequest(method: 'PUT', data: {'idleTimeout': timeout});

  Future<String?> _policyRequest({
    String? method,
    Map<String, dynamic>? data,
  }) async {
    final result = await _exchange(_policyRoute, method: method, data: data);
    if (_unsupported) return null;
    if (result is Map &&
        result['idleTimeout'] is String &&
        _choices.contains(result['idleTimeout'])) {
      return result['idleTimeout'] as String;
    }
    throw const FormatException('Invalid session inactivity policy');
  }

  Future<dynamic> _exchange(
    String route, {
    String? method,
    Map<String, dynamic>? data,
  }) async {
    if (_unsupported) return null;
    try {
      return await _request(
        route,
        method: method,
        data: data,
        notFoundCode: 'SESSION_INACTIVITY_UNAVAILABLE',
      );
    } on ApiFailure catch (failure) {
      if (failure.status != 404) rethrow;
      _unsupported = true;
      return null;
    }
  }

  Future<void> recordActivity() async {
    if (_unsupported || _reporting) return;
    final now = _elapsed();
    final last = _lastAttempt;
    if (last != null && now - last < _interval) return;
    _lastAttempt = now;
    _reporting = true;
    try {
      await _exchange(_activityRoute, method: 'POST');
    } catch (_) {
      // A later foreground input can try again. There is no background retry.
    } finally {
      _reporting = false;
    }
  }
}

/// Capture native keyboard events even when a focused editor consumes them.
class SessionActivityBoundary extends StatefulWidget {
  const SessionActivityBoundary({
    super.key,
    required this.onActivity,
    required this.child,
  });

  final VoidCallback onActivity;
  final Widget child;

  @override
  State<SessionActivityBoundary> createState() =>
      _SessionActivityBoundaryState();
}

class _SessionActivityBoundaryState extends State<SessionActivityBoundary> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_key);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    super.dispose();
  }

  void _report() {
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      widget.onActivity();
    }
  }

  bool _key(KeyEvent event) {
    if (event is KeyDownEvent && !event.synthesized) _report();
    return false;
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) {
      if (!event.synthesized) _report();
    },
    child: widget.child,
  );
}

class SessionInactivityTile extends StatefulWidget {
  const SessionInactivityTile({
    super.key,
    required this.policy,
    required this.russian,
  });

  final SessionInactivity policy;
  final bool russian;

  @override
  State<SessionInactivityTile> createState() => _SessionInactivityTileState();
}

class _SessionInactivityTileState extends State<SessionInactivityTile> {
  String? _timeout;
  bool _busy = false;
  bool _unavailable = false;
  bool _failed = false;

  String _tr(String ru, String en) => widget.russian ? ru : en;
  String get _title => _tr('Выход при бездействии', 'Sign out when inactive');

  String _label(String timeout) => switch (timeout) {
    'never' => _tr('Никогда', 'Never'),
    '1' => _tr('Через 1 день', 'After 1 day'),
    '3' => _tr('Через 3 дня', 'After 3 days'),
    _ => _tr('Через $timeout дней', 'After $timeout days'),
  };

  @override
  void initState() {
    super.initState();
    _loadOrSave();
  }

  Future<void> _loadOrSave([String? choice]) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final result = await (choice == null
          ? widget.policy.load()
          : widget.policy.save(choice));
      if (!mounted) return;
      setState(() {
        _timeout = result;
        _unavailable = result == null;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _choose() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(_title),
        children: [
          for (final timeout in SessionInactivity._choices)
            ListTile(
              title: Text(_label(timeout)),
              selected: timeout == _timeout,
              trailing: timeout == _timeout ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, timeout),
            ),
        ],
      ),
    );
    if (mounted && choice != null && choice != _timeout) {
      await _loadOrSave(choice);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_unavailable) return const SizedBox.shrink();
    final timeout = _timeout;
    return ListTile(
      leading: const Icon(Icons.timelapse),
      title: Text(_title),
      subtitle: Text(
        _failed
            ? _tr(
                'Не удалось изменить или загрузить настройку. Нажмите, чтобы повторить.',
                'Could not load or change this setting. Tap to retry.',
              )
            : timeout == null
            ? _tr('Загрузка…', 'Loading…')
            : _tr(
                '${_label(timeout)} · Только для текущего сеанса.',
                '${_label(timeout)} · This session only.',
              ),
      ),
      onTap: _busy ? null : (timeout == null ? _loadOrSave : _choose),
    );
  }
}
