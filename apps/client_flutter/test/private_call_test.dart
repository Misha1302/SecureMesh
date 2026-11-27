import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/call_media.dart';
import 'package:securemesh_client/private_call.dart';

class Link extends Fake implements CallMedia {
  int opens = 0, closes = 0;
  bool? video;
  Completer<void>? permission;
  late void Function(CallSignal) ice;
  @override
  Future<void> open(
    bool v,
    void Function(CallSignal) onIce,
    void Function(bool) connected,
    VoidCallback failed,
  ) async {
    opens++;
    video = v;
    ice = onIce;
    await permission?.future;
  }

  @override
  Future<String> offer() async {
    ice({'kind': 'ice', 'candidate': 'host', 'mid': '0', 'line': 0});
    return 'local-offer';
  }

  @override
  Future<String> answer(String remote) async => 'local-answer';
  @override
  Future<void> close() async {
    closes++;
  }
}

class Signals {
  final sent = <CallSignal>[], incoming = <Map<String, dynamic>>[];
  String? session;
  String phase = 'invited';
  int seq = 0;
  Future<Map<String, dynamic>> command(
    String op,
    Map<String, dynamic> args,
  ) async {
    if (op == 'call_events') {
      return {
        'events': incoming
            .where((x) => x['seq'] > (args['after'] as int))
            .toList(),
        'session': session,
        'phase': phase,
      };
    }
    session = args['call'] as String;
    final s = args['signal'] as CallSignal;
    if (s['kind'] == 'invite' || s['kind'] == 'accept') {
      expect(args['confirmed'], true);
    }
    sent.add(s);
    return {};
  }

  void push(CallSignal s) {
    incoming.add({
      'seq': ++seq,
      'event': {'sender': 'peer', 'call': session, 'signal': s},
    });
  }
}

Future<void> flush() => Future<void>.delayed(Duration.zero);
void main() {
  test('caller creates no transport or tracks before acceptance, queues local ICE after the offer', () async {
    final s = Signals(), m = Link();
    final c = PrivateCall(
      'g',
      'peer',
      'Peer',
      s.command,
      () {},
      makeMedia: () => m,
    );
    await c.invite(true);
    expect(m.opens, 0);
    expect(s.sent.single, {'kind': 'invite', 'media': 'video'});
    s.push({'kind': 'accept'});
    await c.poll();
    await flush();
    expect(m.opens, 1);
    expect(m.video, true);
    expect(s.sent.map((x) => x['kind']), ['invite', 'offer', 'ice']);
    await c.end();
    m.ice({'kind': 'ice'});
    await flush();
    expect(m.closes, 1);
    expect(s.sent.last['kind'], 'end');
    c.dispose();
  });
  test('declining an invite requests no devices; a remote end cancels pending capture', () async {
    final s = Signals()..session = 'call-1';
    final m = Link();
    final c = PrivateCall(
      'g',
      'peer',
      'Peer',
      s.command,
      () {},
      makeMedia: () => m,
    );
    s.push({'kind': 'invite', 'media': 'audio'});
    await c.poll();
    await flush();
    expect(c.phase, CallPhase.ringing);
    expect(m.opens, 0);
    await c.end();
    expect(m.opens, 0);
    s.session = 'call-2';
    s.push({'kind': 'invite', 'media': 'audio'});
    await c.poll();
    await flush();
    await c.accept();
    expect(m.opens, 0);
    m.permission = Completer<void>();
    s.push({'kind': 'offer', 'sdp': 'remote'});
    await c.poll();
    await flush();
    expect(m.opens, 1);
    expect(m.video, false);
    s.phase = 'ended';
    await c.poll();
    expect(m.closes, 1);
    m.permission!.complete();
    await flush();
    expect(c.active, false);
    expect(s.sent.where((x) => x['kind'] == 'answer'), isEmpty);
    c.dispose();
  });
}
