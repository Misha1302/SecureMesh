import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'call_media.dart';
import 'conversation_drafts.dart';
import 'local_client.dart';

enum CallPhase { idle, inviting, ringing, negotiating, connected, failed }

/// One verified peer in one MLS group. All asynchronous SDP and ICE writes are
/// ordered; cancelling invalidates callbacks even if an OS permission dialog is open.
class PrivateCall extends ChangeNotifier {
  PrivateCall(
    this.group,
    this.peer,
    this.name,
    this.crypto,
    this.wake, {
    this.makeMedia = DirectMedia.new,
  });
  final String group, peer, name;
  final DraftCommand crypto;
  final VoidCallback wake;
  final CallMedia Function() makeMedia;
  CallPhase phase = CallPhase.idle;
  bool video = false, _closed = false, _polling = false, _bound = false;
  String? _id;
  int _cursor = 0, _generation = 0;
  Future<void> _tail = Future.value();
  CallMedia? media;
  Timer? _deadline;
  bool mic = true, camera = true;
  void toggleMic() {
    mic = !mic;
    media?.enableMicrophone(mic);
    changed();
  }

  void toggleCamera() {
    camera = !camera;
    media?.enableCamera(camera);
    changed();
  }

  bool get active => _id != null;
  String? get invitation => _id;
  void changed() {
    if (!_closed) notifyListeners();
  }

  void _timeout(int epoch) {
    _deadline?.cancel();
    _deadline = Timer(const Duration(seconds: 55), () {
      if (!_closed && epoch == _generation) unawaited(end(failed: true));
    });
  }

  Future<void> _ordered(Future<void> Function() body) {
    final epoch = _generation;
    final task = _tail.then((_) async {
      if (_closed || epoch != _generation) return;
      try {
        await body();
      } catch (_) {
        if (!_closed && epoch == _generation) await end(failed: true);
      }
    });
    _tail = task;
    return task;
  }

  Future<void> _signal(
    String id,
    CallSignal signal, {
    bool confirmed = false,
  }) async {
    await crypto('call_queue', {
      'group': group,
      'id': newUuid(),
      'call': id,
      'peer': peer,
      'signal': signal,
      'confirmed': confirmed,
    });
    if (!_closed) wake();
  }

  Future<void> invite(bool withVideo) {
    if (_closed || active) return Future.value();
    _generation++;
    final id = _id = newUuid();
    mic = camera = true;
    video = withVideo;
    phase = CallPhase.inviting;
    _timeout(_generation);
    changed();
    return _ordered(() async {
      await _signal(id, {
        'kind': 'invite',
        'media': video ? 'video' : 'audio',
      }, confirmed: true);
      if (_id == id) _bound = true;
    });
  }

  Future<void> accept() {
    if (_closed || phase != CallPhase.ringing || _id == null) {
      return Future.value();
    }
    final id = _id!;
    phase = CallPhase.negotiating;
    _timeout(_generation);
    changed();
    // The callee creates no media until the accepted caller's offer is authenticated.
    return _ordered(() => _signal(id, {'kind': 'accept'}, confirmed: true));
  }

  Future<void> _start(String id) async {
    final engine = media = makeMedia();
    final epoch = _generation;
    await engine.open(
      video,
      (s) {
        if (epoch == _generation && !_closed && identical(engine, media)) {
          unawaited(_ordered(() => _signal(id, s)));
        }
      },
      (up) {
        if (_closed || epoch != _generation) return;
        phase = up ? CallPhase.connected : CallPhase.negotiating;
        if (up) {
          _deadline?.cancel();
        } else {
          _timeout(epoch);
        }
        changed();
      },
      () {
        if (!_closed && epoch == _generation) unawaited(end(failed: true));
      },
    );
    if (_closed || epoch != _generation) throw StateError('closed');
    changed();
  }

  Future<void> _event(Map<String, dynamic> e) async {
    if (e['sender'] != peer) return;
    final id = e['call'] as String;
    final s = Map<String, dynamic>.from(e['signal'] as Map);
    if (s['kind'] == 'invite') {
      if (active) return;
      _id = id;
      _bound = true;
      mic = camera = true;
      video = s['media'] == 'video';
      phase = CallPhase.ringing;
      _timeout(_generation);
      changed();
      return;
    }
    if (id != _id) return;
    final epoch = _generation;
    switch (s['kind']) {
      case 'accept':
        if (phase != CallPhase.inviting) return;
        phase = CallPhase.negotiating;
        _timeout(epoch);
        changed();
        await _start(id);
        final offer = await media!.offer();
        if (epoch == _generation) {
          await _signal(id, {'kind': 'offer', 'sdp': offer});
        }
      case 'offer':
        if (phase != CallPhase.negotiating || media != null) return;
        await _start(id);
        final answer = await media!.answer(s['sdp'] as String);
        if (epoch == _generation) {
          await _signal(id, {'kind': 'answer', 'sdp': answer});
        }
      case 'answer':
        await media!.remoteAnswer(s['sdp'] as String);
      case 'ice':
        await media!.candidate(s);
      case 'end':
        await end(notifyPeer: false);
    }
  }

  Future<void> poll() async {
    if (_closed || _polling) return;
    _polling = true;
    final epoch = _generation;
    try {
      final result = await crypto('call_events', {
        'group': group,
        'after': _cursor,
      });
      if (_closed || epoch != _generation) return;
      if (_bound &&
          active &&
          (result['session'] != _id || result['phase'] == 'ended')) {
        await end(notifyPeer: false);
      }
      for (final item in result['events'] as List) {
        _cursor = item['seq'] as int;
        final e = Map<String, dynamic>.from(item['event'] as Map);
        if (result['phase'] != 'ended') unawaited(_ordered(() => _event(e)));
      }
    } catch (_) {
      if (!_closed && epoch == _generation && active) await end(failed: true);
    } finally {
      _polling = false;
    }
  }

  Future<void> end({bool failed = false, bool notifyPeer = true}) async {
    final id = _id;
    _id = null;
    _bound = false;
    _generation++;
    _deadline?.cancel();
    final engine = media;
    media = null;
    phase = failed ? CallPhase.failed : CallPhase.idle;
    changed();
    final stopped = engine?.close().catchError((_) {});
    if (id != null && notifyPeer) {
      try {
        await _signal(id, {'kind': 'end'});
      } catch (_) {}
    }
    await stopped;
  }

  void dismiss() {
    if (!active) {
      phase = CallPhase.idle;
      changed();
    }
  }

  @override
  void dispose() {
    _closed = true;
    unawaited(end());
    super.dispose();
  }
}

class CallPanel extends StatelessWidget {
  const CallPanel(this.call, this.tr, {super.key});
  final PrivateCall call;
  final String Function(String, String) tr;
  @override
  Widget build(BuildContext context) {
    if (call.phase == CallPhase.idle) return const SizedBox.shrink();
    final mediaName = call.video
        ? tr('видеозвонок', 'video call')
        : tr('аудиозвонок', 'audio call');
    final title = switch (call.phase) {
      CallPhase.inviting => tr('Ожидание ответа', 'Waiting for an answer'),
      CallPhase.ringing => tr('Входящий $mediaName', 'Incoming $mediaName'),
      CallPhase.negotiating => tr(
        'Устанавливается прямое соединение',
        'Establishing direct connection',
      ),
      CallPhase.connected => tr('Звонок подключён', 'Call connected'),
      CallPhase.failed => tr(
        'Звонок не состоялся. Проверьте разрешения и соединение с собеседником.',
        'Call failed. Check permissions and the direct network path.',
      ),
      CallPhase.idle => '',
    };
    return Material(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (call.video && call.media != null)
            SizedBox(height: 120, child: call.media!.videoView()),
          ListTile(
            title: Text(title),
            subtitle: Text(call.name),
            trailing: call.phase == CallPhase.failed
                ? IconButton(
                    tooltip: tr('Закрыть', 'Dismiss'),
                    icon: const Icon(Icons.close),
                    onPressed: call.dismiss,
                  )
                : IconButton(
                    tooltip: tr('Завершить или отклонить', 'End or decline'),
                    onPressed: call.end,
                    icon: const Icon(Icons.call_end),
                  ),
          ),
          if (call.phase == CallPhase.connected)
            Wrap(
              children: [
                IconButton(
                  tooltip: call.mic
                      ? tr('Выключить микрофон', 'Mute microphone')
                      : tr('Включить микрофон', 'Unmute microphone'),
                  onPressed: call.toggleMic,
                  icon: Icon(call.mic ? Icons.mic : Icons.mic_off),
                ),
                if (call.video)
                  IconButton(
                    tooltip: call.camera
                        ? tr('Выключить камеру', 'Disable camera')
                        : tr('Включить камеру', 'Enable camera'),
                    onPressed: call.toggleCamera,
                    icon: Icon(
                      call.camera ? Icons.videocam : Icons.videocam_off,
                    ),
                  ),
              ],
            ),
          if (call.phase == CallPhase.ringing)
            Wrap(
              children: [
                FilledButton(
                  onPressed: () async {
                    final invitation = call.invitation;
                    final approved = await confirmDirectCall(
                      context,
                      call.video,
                      call.name,
                      tr,
                    );
                    if (approved &&
                        context.mounted &&
                        call.phase == CallPhase.ringing &&
                        invitation == call.invitation) {
                      await call.accept();
                    }
                  },
                  child: Text(tr('Ответить', 'Answer')),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

Future<bool> confirmDirectCall(
  BuildContext context,
  bool video,
  String name,
  String Function(String, String) tr,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          video
              ? tr('Видеозвонок с $name', 'Video call with $name')
              : tr('Аудиозвонок с $name', 'Audio call with $name'),
        ),
        content: Text(
          video
              ? tr(
                  'Разрешить микрофон и камеру? При прямом соединении собеседник может видеть ваш IP-адрес.',
                  'Share your microphone and camera? A direct connection can reveal your IP address to this contact.',
                )
              : tr(
                  'Разрешить микрофон? При прямом соединении собеседник может видеть ваш IP-адрес.',
                  'Share your microphone? A direct connection can reveal your IP address to this contact.',
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('Отмена', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('Продолжить', 'Continue')),
          ),
        ],
      ),
    ) ??
    false;
