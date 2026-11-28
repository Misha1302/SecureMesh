import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:securemesh_client/transport.dart';

class _PendingUpgrade implements HttpClient {
  final opening = Completer<HttpClientRequest>();
  int attempts = 0;
  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    attempts++;
    return opening.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'concurrent callers share one upgrade deadline and serialize fallback',
    () async {
      final http = _PendingUpgrade();
      final gates = List.generate(3, (_) => Completer<void>());
      final started = List.generate(3, (_) => Completer<void>());
      var calls = 0, active = 0;
      final transport = MeshTransport(
        endpoint: Uri.https('localhost'),
        device: '00000000-0000-4000-8000-000000000001',
        token: () => 'fixture',
        http: http,
        upgradeTimeout: const Duration(milliseconds: 20),
        https: (route, {data}) async {
          final index = calls++;
          expect(++active, 1);
          started[index].complete();
          await gates[index].future;
          active--;
          if (index == 0) throw TimeoutException('fixture');
          return <String, dynamic>{};
        },
      );
      final results = List.generate(
        3,
        (_) => transport
            .sync(transport.device, '')
            .then(
              (_) => true,
              onError: (Object error) {
                expect(error, isA<TimeoutException>());
                return false;
              },
            ),
      );
      for (var i = 0; i < gates.length; i++) {
        await started[i].future;
        expect(calls, i + 1);
        gates[i].complete();
      }
      expect(await Future.wait(results), [false, true, true]);
      expect(http.attempts, 1);
      expect(transport.upgradeTimeouts, 1);
      expect(transport.helloTimeouts + transport.frameTimeouts, 0);
      expect(transport.fallbackAttempts, 3);
      expect(transport.fallbackTimeouts, 1);
      transport.close();
      http.opening.completeError(const SocketException('fixture cleanup'));
    },
  );

  test('close prevents queued recovery calls from reaching HTTPS', () async {
    final http = _PendingUpgrade();
    final active = Completer<void>(), release = Completer<void>();
    var calls = 0;
    final transport = MeshTransport(
      endpoint: Uri.https('localhost'),
      device: '00000000-0000-4000-8000-000000000001',
      token: () => 'fixture',
      http: http,
      https: (route, {data}) async {
        calls++;
        active.complete();
        await release.future;
        return <String, dynamic>{};
      },
    );
    final first = transport.sync(transport.device, '');
    final second = expectLater(
      transport.sync(transport.device, ''),
      throwsA(isA<SocketException>()),
    );
    http.opening.completeError(const SocketException('offline'));
    await active.future;
    transport.close();
    release.complete();
    await first;
    await second;
    expect(calls, 1);
    expect(transport.upgradeAttempts, 1);
  });
}
