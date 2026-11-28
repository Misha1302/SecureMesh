import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:securemesh_client/delivery_client.dart';
import 'package:securemesh_client/local_client.dart';
import 'package:securemesh_client/session.dart';
import 'package:securemesh_client/src/rust/api.dart';
import 'package:securemesh_client/src/rust/frb_generated.dart';
import 'package:securemesh_client/tls_client.dart';
import 'package:securemesh_client/transport.dart';

Future<Map<String, dynamic>> command(
  NativeClient store,
  String op, [
  Map<String, dynamic> args = const {},
]) async =>
    jsonDecode(await store.execute(request: jsonEncode({'op': op, ...args})))
        as Map<String, dynamic>;
double percentile(List<double> values, double p) {
  final sorted = [...values]..sort();
  return sorted[max(0, (sorted.length * p).ceil() - 1)];
}

// Linux /proc/PID/stat fields 14 and 15 aggregate all process threads.
int processCpuTicks() {
  final stat = File('/proc/self/stat').readAsStringSync();
  final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
  return int.parse(fields[11]) + int.parse(fields[12]);
}

Future<void> main(List<String> args) async {
  final fixture = jsonDecode(File(args.single).readAsStringSync()) as Map;
  await RustLib.init(
    externalLibrary: ExternalLibrary.open(fixture['library'] as String),
  );
  final stores = <NativeClient>[],
      clients = <HttpClient>[],
      sessions = <AccountSession>[],
      transports = <MeshTransport>[],
      pumps = <NativeDelivery>[];
  final group = fixture['group'] as String,
      count = fixture['count'] as int,
      seed = fixture['seed'] as int;
  final outage = fixture['outage'] as Map?;
  final baseline = outage?['baseline'] as int?;
  final outageIds = <Set<String>>[{}, {}];
  double? restoreStarted;
  final sent = <String, Map<String, dynamic>>{}, received = <String, double>{};
  final expectedTexts = <String, String>{};
  final clock = Stopwatch();
  double now() => clock.elapsedMicroseconds / 1000000;
  var stop = false;
  var retries = 0, httpsRequests = 0;
  final errors = <String>[];
  List<Map<String, Object>> transportCounters() => [
    for (final t in transports)
      {
        'mode': t.mode,
        'upgrade_attempts': t.upgradeAttempts,
        'upgrade_timeouts': t.upgradeTimeouts,
        'upgrade_io_failures': t.upgradeIoFailures,
        'hello_timeouts': t.helloTimeouts,
        'frame_timeouts': t.frameTimeouts,
        'fallback_attempts': t.fallbackAttempts,
        'fallback_timeouts': t.fallbackTimeouts,
        'fallback_io_failures': t.fallbackIoFailures,
      },
  ];
  Timer? reporting;
  try {
    for (final device in fixture['devices'] as List) {
      final store = await NativeClient.open(
        path: device['path'] as String,
        passphrase: device['passphrase'] as String,
      );
      stores.add(store);
      final context = SecurityContext(withTrustedRoots: true)
        ..setTrustedCertificates(fixture['cert'] as String);
      final http = meshTlsClient(context)..maxConnectionsPerHost = 4;
      clients.add(http);
      var profile = Map<String, dynamic>.from(device['session'] as Map);
      final endpoint = Uri.parse(device['endpoint'] as String);
      final session = AccountSession(
        http: http,
        endpoint: endpoint,
        profile: () => profile,
        persist: (updated) async {
          final next = {...profile, ...updated};
          await command(store, 'profile_put', {'profile': next});
          profile = next;
        },
      );
      sessions.add(session);
      final transport = MeshTransport(
        endpoint: endpoint,
        device: device['id'] as String,
        token: () => profile['accessToken'] as String,
        http: http,
        https: (route, {data}) {
          httpsRequests++;
          return session.request(route, data: data);
        },
      );
      transports.add(transport);
      final highestOrdinal = <String, int>{};
      pumps.add(
        NativeDelivery(
          transport: transport,
          crypto: (op, [args = const {}]) async {
            if (op != 'ingest') return command(store, op, args);
            final sender = args['sender'] as String;
            final ordinal = sent[args['id']]?['ordinal'] as int?;
            try {
              final result = await command(store, op, args);
              if (ordinal != null) {
                highestOrdinal[sender] = max(
                  highestOrdinal[sender] ?? -1,
                  ordinal,
                );
              }
              return result;
            } catch (_) {
              // Only fixture counters. Never print event contents, keys or tokens.
              stderr.writeln(
                'Native trial ingest rejected: serverSeq=${args['seq']} '
                'senderOrdinal=$ordinal previousHighest=${highestOrdinal[sender]} '
                'own=${sender == device['id']}',
              );
              rethrow;
            }
          },
        ),
      );
      await transport.sync(group, '');
    }
    stdout.writeln('WARM_READY');
    await stdout.flush();
    await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
    final initialCpuTicks = processCpuTicks();
    clock.start();
    reporting = Timer.periodic(const Duration(seconds: 10), (_) {
      File(fixture['progress'] as String).writeAsStringSync(
        jsonEncode({
          'profile': fixture['profile'],
          'seed': seed,
          'offered': sent.length,
          'received': received.length,
          'elapsed_seconds': now(),
          'retries': retries,
          'transports': transportCounters(),
        }),
      );
    });
    final interval = fixture['profile'] == 'severe' ? 1500 : 1000;
    Future<void> offer(
      int index,
      int from,
      int until, {
      bool offline = false,
    }) async {
      final rng = Random(seed + index),
          alphabet = 'abcПривет🌍'.runes.map(String.fromCharCode).toList();
      for (var i = from; i < until; i++) {
        final remaining = offline
            ? 0
            : i * interval - clock.elapsedMilliseconds;
        if (remaining > 0) {
          await Future<void>.delayed(Duration(milliseconds: remaining));
        }
        final id = newUuid(), characters = 1 + rng.nextInt(400);
        final text = List.generate(
          characters,
          (_) => alphabet[rng.nextInt(alphabet.length)],
        ).join();
        if (offline) outageIds[index].add(id);
        expectedTexts[id] = text;
        sent[id] = {
          'id': id,
          'sender': (fixture['devices'] as List)[index]['id'],
          'ordinal': i,
          'start': now(),
          'characters': characters,
          'utf8_bytes': utf8.encode(text).length,
        };
        await command(stores[index], 'queue', {
          'group': group,
          'id': id,
          'text': text,
        });
      }
    }

    Future<void> pump(int index) async {
      var failures = 0;
      final rng = Random(seed + index + 100);
      while (!stop) {
        Duration delay;
        try {
          final progress = await pumps[index].tick(group);
          failures = 0;
          delay = progress.delay;
          final history =
              (await command(stores[index], 'history', {
                    'group': group,
                  }))['events']
                  as List;
          final ids = history.map((e) => e['id']).toSet();
          if (ids.length != history.length) {
            throw StateError('LOGICAL_DUPLICATE');
          }
          for (final event in history) {
            final id = event['id'] as String;
            final expected = sent[id];
            if (expected == null) throw StateError('UNEXPECTED_MESSAGE');
            if (expected['sender'] != fixture['devices'][1 - index]['id'] ||
                event['text'] != expectedTexts[id]) {
              throw StateError('RECIPIENT_OR_CONTENT_MISMATCH');
            }
            received.putIfAbsent(id, now);
          }
        } on ApiFailure catch (e) {
          retries++;
          failures++;
          errors.add('API_${e.status}_${e.code}');
          delay = Duration(seconds: min(30, 1 << min(failures, 5)));
        } on IOException {
          retries++;
          failures++;
          errors.add('NETWORK');
          delay = Duration(seconds: min(30, 1 << min(failures, 5)));
        } on TimeoutException {
          retries++;
          failures++;
          errors.add('TIMEOUT');
          delay = Duration(seconds: min(30, 1 << min(failures, 5)));
        }
        if (errors.length > 100) errors.removeAt(0);
        if (now() > 1200) {
          throw TimeoutException('Eventual-delivery watchdog exceeded');
        }
        await Future<void>.delayed(
          delay +
              Duration(
                milliseconds: rng.nextInt(
                  delay.inMilliseconds < 1000 ? 100 : 600,
                ),
              ),
        );
      }
    }

    final pumping = [pump(0), pump(1)];
    // Observe failures immediately; never wait out the watchdog after a crypto error.
    Object? fatal;
    StackTrace? fatalStack;
    for (final task in pumping) {
      unawaited(
        task.catchError((Object error, StackTrace stack) {
          fatal = error;
          fatalStack = stack;
          stop = true;
        }),
      );
    }
    Future<void> waitUntil(
      FutureOr<bool> Function() ready,
      String error,
    ) async {
      while (!await ready()) {
        if (fatal != null) Error.throwWithStackTrace(fatal!, fatalStack!);
        if (now() > 1200) throw TimeoutException(error);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    Future<Set<String>> outboxIds(int index) async {
      final rows = (await command(stores[index], 'outbox'))['messages'] as List;
      return rows.map((row) => row['id'] as String).toSet();
    }

    if (outage != null && baseline != null) {
      File marker(String phase) => File('${outage['control']}/$phase');
      await Future.wait([offer(0, 0, baseline), offer(1, 0, baseline)]);
      await waitUntil(
        () => received.length == baseline * 2,
        'Baseline messages missing',
      );
      for (var i = 0; i < stores.length; i++) {
        await waitUntil(
          () async => (await outboxIds(i)).isEmpty,
          'Baseline outbox not empty',
        );
      }
      marker('baseline-ready').createSync();
      await waitUntil(
        () => marker('outage-active').existsSync(),
        'Blackout was not applied',
      );
      await Future.wait([
        offer(0, baseline, count, offline: true),
        offer(1, baseline, count, offline: true),
      ]);
      Future<void> assertQueuedDuringOutage() async {
        if (received.length != baseline * 2) {
          throw StateError('DELIVERED_DURING_OUTAGE');
        }
        for (var i = 0; i < stores.length; i++) {
          final ids = await outboxIds(i);
          if (ids.length != outageIds[i].length ||
              !ids.containsAll(outageIds[i])) {
            throw StateError('OFFLINE_OUTBOX_NOT_DURABLE');
          }
        }
      }

      await assertQueuedDuringOutage();
      marker('offline-queued').createSync();
      await waitUntil(
        () => marker('restore-starting').existsSync(),
        'Restoration was not signalled',
      );
      await assertQueuedDuringOutage();
      // Start the clock before Linux restores either network path.
      restoreStarted = now();
      marker('restore-timer-ready').createSync();
    } else {
      await Future.wait([offer(0, 0, count), offer(1, 0, count)]);
    }
    await waitUntil(
      () => received.length == count * 2,
      'Missing durable messages',
    );
    for (var i = 0; i < stores.length; i++) {
      await waitUntil(
        () async => (await outboxIds(i)).isEmpty,
        'Outbox did not drain',
      );
    }
    stop = true;
    await Future.wait(pumping);
    if (sent.length != count * 2 ||
        !sent.keys.toSet().containsAll(received.keys)) {
      throw StateError('MISSING_IDS');
    }
    final records = sent.entries
        .map(
          (e) => {
            ...e.value,
            'delivery_seconds': received[e.key]! - (e.value['start'] as double),
            if (restoreStarted != null &&
                outageIds.any((ids) => ids.contains(e.key)))
              'recovery_seconds': received[e.key]! - restoreStarted,
          },
        )
        .toList();
    final delays = records.map((e) => e['delivery_seconds'] as double).toList();
    for (final store in stores) {
      final events =
          (await command(store, 'history', {'group': group}))['events'] as List;
      if (events.length != count) throw StateError('HISTORY_COUNT_MISMATCH');
    }
    final recovery = records
        .map((row) => row['recovery_seconds'])
        .whereType<double>()
        .toList();
    final result = {
      'profile': fixture['profile'],
      'seed': seed,
      'messages_each_direction': count,
      'delivery_p50': percentile(delays, .5),
      'delivery_p95': percentile(delays, .95),
      'delivery_p99': percentile(delays, .99),
      if (outage != null)
        'outage': {
          'requested_blackout_seconds': outage['seconds'],
          'baseline_confirmed_each_direction': baseline,
          'offline_queued_each_direction': outageIds
              .map((ids) => ids.length)
              .toList(),
          'offline_delivered_before_restore': 0,
          'recovery_p50': percentile(recovery, .5),
          'recovery_p95': percentile(recovery, .95),
          'recovery_p99': percentile(recovery, .99),
          'recovery_p95_limit_seconds': outage['p95_limit'],
        },
      'duplicates': 0,
      'missing_ids': 0,
      'elapsed_seconds': now(),
      if (fixture['clock_ticks_per_second'] case final int hz)
        'client_process_cpu_seconds':
            (processCpuTicks() - initialCpuTicks) / hz,
      'client_process_peak_rss_bytes': ProcessInfo.maxRss,
      'retries': retries,
      'transports': transportCounters(),
      'recent_errors': errors,
      'https_requests': httpsRequests,
      'wss_application_bytes_sent': transports
          .map((t) => t.sentApplicationBytes)
          .toList(),
      'wss_application_bytes_received': transports
          .map((t) => t.receivedApplicationBytes)
          .toList(),
      'records': records,
      'platform': 'Linux native Dart; production NativeDelivery/MeshTransport/FRB/OpenMLS/SQLCipher',
    };
    File(fixture['output'] as String).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(result)}\n',
    );
    stdout.writeln(jsonEncode({...result}..remove('records')));
    if (outage != null &&
        percentile(recovery, .95) > (outage['p95_limit'] as int)) {
      throw StateError('RECOVERY_P95_EXCEEDED');
    }
    const limits = {'gprs': 15, '3g': 8, '4g': 5, '5g': 5};
    final limit = limits[fixture['profile']];
    if (limit != null && (result['delivery_p95'] as double) > limit) {
      throw StateError('DELIVERY_P95_EXCEEDED_${limit}_SECONDS');
    }
  } finally {
    reporting?.cancel();
    stop = true;
    for (final p in pumps) {
      p.close();
    }
    for (final t in transports) {
      t.close();
    }
    for (final s in sessions) {
      s.close();
    }
    for (final c in clients) {
      c.close(force: true);
    }
    for (final s in stores) {
      s.dispose();
    }
    RustLib.dispose();
  }
}
