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
  final sent = <String, Map<String, dynamic>>{}, received = <String, double>{};
  final expectedTexts = <String, String>{};
  final clock = Stopwatch();
  double now() => clock.elapsedMicroseconds / 1000000;
  var stop = false;
  var retries = 0, httpsRequests = 0;
  final errors = <String>[];
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
        }),
      );
    });
    final interval = fixture['profile'] == 'severe' ? 1500 : 1000;
    Future<void> offer(int index) async {
      final rng = Random(seed + index),
          alphabet = 'abcПривет🌍'.runes.map(String.fromCharCode).toList();
      for (var i = 0; i < count; i++) {
        final remaining = i * interval - clock.elapsedMilliseconds;
        if (remaining > 0) {
          await Future<void>.delayed(Duration(milliseconds: remaining));
        }
        final id = newUuid(), characters = 1 + rng.nextInt(400);
        final text = List.generate(
          characters,
          (_) => alphabet[rng.nextInt(alphabet.length)],
        ).join();
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
    await Future.wait([offer(0), offer(1)]);
    while (received.length != count * 2) {
      if (fatal != null) Error.throwWithStackTrace(fatal!, fatalStack!);
      if (now() > 1200) throw TimeoutException('Missing durable messages');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    for (var i = 0; i < 2; i++) {
      while ((await command(stores[i], 'outbox'))['messages'].isNotEmpty) {
        if (fatal != null) Error.throwWithStackTrace(fatal!, fatalStack!);
        if (now() > 1200) throw TimeoutException('Outbox did not drain');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
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
          },
        )
        .toList();
    final delays = records.map((e) => e['delivery_seconds'] as double).toList();
    for (final store in stores) {
      final events =
          (await command(store, 'history', {'group': group}))['events'] as List;
      if (events.length != count) throw StateError('HISTORY_COUNT_MISMATCH');
    }
    final result = {
      'profile': fixture['profile'],
      'seed': seed,
      'messages_each_direction': count,
      'delivery_p50': percentile(delays, .5),
      'delivery_p95': percentile(delays, .95),
      'delivery_p99': percentile(delays, .99),
      'duplicates': 0,
      'missing_ids': 0,
      'elapsed_seconds': now(),
      'client_process_peak_rss_bytes': ProcessInfo.maxRss,
      'retries': retries,
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
