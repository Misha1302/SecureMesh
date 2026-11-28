import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:securemesh_client/delivery_client.dart';
import 'package:securemesh_client/session.dart';
import 'package:securemesh_client/src/rust/api.dart';
import 'package:securemesh_client/src/rust/frb_generated.dart';
import 'package:securemesh_client/tls_client.dart';
import 'package:securemesh_client/transport.dart';

class ObservedTransport extends MeshTransport {
  ObservedTransport({
    required super.endpoint,
    required super.device,
    required super.token,
    required super.http,
    required super.https,
  });

  int pages = 0;
  int continuedPages = 0;
  int maxPageSize = 0;

  @override
  Future<Map<String, dynamic>> sync(
    String group,
    String cursor, {
    int limit = 6,
  }) async {
    final page = await super.sync(group, cursor, limit: limit);
    final size = (page['messages'] as List).length;
    if (size > 0) {
      pages++;
      if (cursor.isNotEmpty) continuedPages++;
      if (size > maxPageSize) maxPageSize = size;
    }
    return page;
  }
}

String fixtureText(int ordinal) => 'Offline backlog №$ordinal • Привет 🌍';

double percentile(List<double> sorted, double p) =>
    sorted[(sorted.length * p).ceil() - 1];

Future<void> main(List<String> args) async {
  final fixture = jsonDecode(File(args.single).readAsStringSync()) as Map;
  final group = fixture['group'] as String;
  final epoch = fixture['epoch'] as int;
  final ids = (fixture['ids'] as List).cast<String>();
  final ordinals = {for (var i = 0; i < ids.length; i++) ids[i]: i};
  final elapsedById = <String, double>{};
  final replayClock = Stopwatch();
  final stores = <NativeClient>[];
  final clients = <HttpClient>[];
  final sessions = <AccountSession>[];
  final transports = <ObservedTransport>[];
  final pumps = <NativeDelivery>[];
  final failures = <String, int>{};
  var duplicateIngests = 0;
  await RustLib.init(
    externalLibrary: ExternalLibrary.open(fixture['library'] as String),
  );

  Future<Map<String, dynamic>> crypto(
    int index,
    String op, [
    Map<String, dynamic> args = const {},
  ]) async => jsonDecode(
    await stores[index].execute(request: jsonEncode({'op': op, ...args})),
  ) as Map<String, dynamic>;

  try {
    final devices = fixture['devices'] as List;
    final sender = devices.first['id'] as String;
    for (final (index, device) in devices.indexed) {
      stores.add(
        await NativeClient.open(
          path: device['path'] as String,
          passphrase: device['passphrase'] as String,
        ),
      );
      final context = SecurityContext(withTrustedRoots: true)
        ..setTrustedCertificates(fixture['cert'] as String);
      final http = meshTlsClient(context)..maxConnectionsPerHost = 4;
      clients.add(http);
      final endpoint = Uri.parse(fixture['endpoint'] as String);
      var profile = Map<String, dynamic>.from(device['session'] as Map);
      final session = AccountSession(
        http: http,
        endpoint: endpoint,
        profile: () => profile,
        persist: (update) async {
          profile = {...profile, ...update};
          await crypto(index, 'profile_put', {'profile': profile});
        },
      );
      sessions.add(session);
      final transport = ObservedTransport(
        endpoint: endpoint,
        device: device['id'] as String,
        token: () => profile['accessToken'] as String,
        http: http,
        https: (route, {data}) => session.request(route, data: data),
      );
      transports.add(transport);
      pumps.add(
        NativeDelivery(
          transport: transport,
          crypto: (op, [arguments = const {}]) async {
            final result = await crypto(index, op, arguments);
            if (index == 1 && op == 'ingest') {
              final id = arguments['id'] as String;
              final ordinal = ordinals[id];
              if (ordinal == null ||
                  arguments['sender'] != sender ||
                  arguments['epoch'] != epoch ||
                  arguments['kind'] != 1) {
                throw StateError('UNEXPECTED_RECIPIENT_ENVELOPE');
              }
              if (result['duplicate'] == true) {
                duplicateIngests++;
              } else {
                if (result['event']['text'] != fixtureText(ordinal) ||
                    elapsedById.containsKey(id)) {
                  throw StateError('RECIPIENT_CONTENT_OR_ID_MISMATCH');
                }
                elapsedById[id] = replayClock.elapsedMicroseconds / 1000000;
              }
            }
            return result;
          },
        ),
      );
    }

    final firstPage = (await crypto(0, 'outbox'))['messages'] as List;
    if (jsonEncode(firstPage.map((row) => row['id']).toList()) !=
        jsonEncode(ids.take(100).toList())) {
      throw StateError('REOPENED_OUTBOX_PREFIX_MISMATCH');
    }

    replayClock.start();
    var delays = [Duration.zero, Duration.zero];
    var next = [Duration.zero, Duration.zero];
    while (true) {
      await Future.wait([
        for (final (index, pump) in pumps.indexed)
          if (replayClock.elapsed >= next[index])
            () async {
              try {
                delays[index] = (await pump.tick(group)).delay;
              } on ApiFailure catch (error) {
                if (error.status < 500 && error.status != 429) rethrow;
                failures.update(
                  'API_${error.status}',
                  (n) => n + 1,
                  ifAbsent: () => 1,
                );
                delays[index] = const Duration(seconds: 2);
              } on TimeoutException {
                failures.update('timeout', (n) => n + 1, ifAbsent: () => 1);
                delays[index] = const Duration(seconds: 2);
              } on IOException {
                failures.update('io', (n) => n + 1, ifAbsent: () => 1);
                delays[index] = const Duration(seconds: 2);
              }
              next[index] = replayClock.elapsed + delays[index];
            }(),
      ]);
      if (elapsedById.length == ids.length &&
          (await crypto(0, 'outbox_pending'))['pending'] == false) {
        final finalCursor = await crypto(1, 'cursor', {'group': group});
        if (finalCursor['seq'] != ids.length ||
            (finalCursor['cursor'] as String).isEmpty) {
          throw StateError('RECIPIENT_CURSOR_INCOMPLETE');
        }
        // Observing the recipient receipt through the sender also establishes
        // completion of the production recipient upload of that receipt.
        final senderCursor = await crypto(0, 'cursor', {'group': group});
        final page = await transports[0].sync(
          group,
          senderCursor['cursor'] as String,
        );
        if (page['peerProcessedSequence'] == ids.length) break;
      }
      if (replayClock.elapsed > const Duration(seconds: 180)) {
        throw TimeoutException('BACKLOG_DEADLINE_${elapsedById.length}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    final replaySeconds = replayClock.elapsedMicroseconds / 1000000;
    final receiver = transports[1];
    if (receiver.pages < 2 ||
        receiver.continuedPages < 1 ||
        receiver.maxPageSize > 6 ||
        replaySeconds > 180) {
      throw StateError('SYNCHRONIZATION_GATE');
    }
    final sorted = elapsedById.values.toList()..sort();
    File(fixture['output'] as String).writeAsStringSync(
      jsonEncode({
        'count': ids.length,
        'epoch': epoch,
        'elapsed_seconds': replaySeconds,
        'recovery_p50_seconds': percentile(sorted, .50),
        'recovery_p95_seconds': percentile(sorted, .95),
        'recovery_p99_seconds': percentile(sorted, .99),
        'recipient_nonempty_sync_pages': receiver.pages,
        'recipient_continued_sync_pages': receiver.continuedPages,
        'recipient_max_sync_page_size': receiver.maxPageSize,
        'duplicate_transport_ingests': duplicateIngests,
        'transport_retry_failures': failures,
        'transport_modes': transports.map((t) => t.mode).toList(),
        'recipient_committed_latencies_seconds': [
          for (final id in ids) elapsedById[id],
        ],
      }),
    );
  } finally {
    for (final pump in pumps) {
      pump.close();
    }
    for (final transport in transports) {
      transport.close();
    }
    for (final session in sessions) {
      session.close();
    }
    for (final client in clients) {
      client.close(force: true);
    }
    for (final store in stores) {
      store.dispose();
    }
    RustLib.dispose();
  }
}
