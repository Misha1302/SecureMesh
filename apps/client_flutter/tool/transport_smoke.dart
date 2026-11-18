import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:securemesh_client/src/rust/api.dart';
import 'package:securemesh_client/src/rust/frb_generated.dart';
import 'package:securemesh_client/transport.dart';

void require(bool value, String code) {
  if (!value) throw StateError(code);
}

Future<Map<String, dynamic>> crypto(
  NativeClient store,
  String op, [
  Map<String, dynamic> args = const {},
]) async =>
    jsonDecode(await store.execute(request: jsonEncode({'op': op, ...args})))
        as Map<String, dynamic>;

Future<void> main(List<String> args) async {
  final fixture =
      jsonDecode(File(args.single).readAsStringSync()) as Map<String, dynamic>;
  await RustLib.init(
    externalLibrary: ExternalLibrary.open(fixture['library'] as String),
  );
  final stores = <NativeClient>[],
      clients = <HttpClient>[],
      transports = <MeshTransport>[];
  final mode = File(fixture['mode'] as String);
  final group = fixture['group'] as String;
  final endpoint = Uri.parse(fixture['endpoint'] as String);
  try {
    for (final d in fixture['devices'] as List) {
      stores.add(
        await NativeClient.open(
          path: d['path'] as String,
          passphrase: d['passphrase'] as String,
        ),
      );
      final context = SecurityContext(withTrustedRoots: true)
        ..setTrustedCertificates(fixture['cert'] as String);
      final http = HttpClient(context: context)
        ..connectionTimeout = const Duration(seconds: 2);
      clients.add(http);
      transports.add(
        MeshTransport(
          endpoint: endpoint,
          device: d['id'] as String,
          token: () => d['token'] as String,
          http: http,
          timeout: const Duration(seconds: 1),
          probeDelay: const Duration(milliseconds: 100),
          https: (route, {data}) async {
            final req = await http.openUrl(
              data == null ? 'GET' : 'POST',
              endpoint.resolve(route),
            );
            req.headers.set(
              HttpHeaders.authorizationHeader,
              'Bearer ${d['token']}',
            );
            req.headers.contentType = ContentType.json;
            if (data != null) {
              req.write(jsonEncode(data));
            }
            final response = await req.close().timeout(
              const Duration(seconds: 3),
            );
            final body = await utf8.decoder.bind(response).join();
            final value = body.isEmpty ? null : jsonDecode(body);
            if (response.statusCode >= 400)
              throw ApiFailure(
                response.statusCode,
                (value as Map)['code'] as String,
              );
            return value;
          },
        ),
      );
    }
    final sent = <String>{};
    Future<Map<String, dynamic>> queue(int index) async {
      final random = Random.secure();
      final id = uuidString(List.generate(16, (_) => random.nextInt(256)));
      sent.add(id);
      return crypto(stores[index], 'queue', {
        'group': group,
        'id': id,
        'text': 'Native transport private fixture $index',
      });
    }

    Future<void> send(int index, {bool duplicate = false}) async {
      final m = await queue(index);
      final ack = await transports[index].send(m);
      require(
        ack['durable'] == true && ack['alreadyCommitted'] == duplicate,
        'ACK_SEMANTICS: expected duplicate=$duplicate, actual=${ack['alreadyCommitted']}, mode=${transports[index].mode}',
      );
      await crypto(stores[index], 'saved', {
        'group': group,
        'id': m['id'],
        'seq': ack['serverSequence'],
      });
    }

    await send(0);
    await send(1);
    require(transports.every((t) => t.mode == 'wss'), 'WSS_NOT_PRIMARY');
    mode.writeAsStringSync('halfopen');
    await send(0);
    require(transports[0].mode == 'https', 'HALFOPEN_NO_FALLBACK');
    mode.writeAsStringSync('pass');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await send(0);
    require(transports[0].mode == 'wss', 'WSS_DID_NOT_RECOVER');
    mode.writeAsStringSync('lostack');
    await send(0, duplicate: true);
    require(transports[0].mode == 'https', 'LOST_ACK_NO_FALLBACK');
    mode.writeAsStringSync('blocked');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await send(0);
    require(transports[0].mode == 'https', 'BLOCKED_WSS_NO_FALLBACK');
    mode.writeAsStringSync('pass');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await send(0);
    mode.writeAsStringSync('malformed');
    final bad = await queue(0);
    var rejected = false;
    try {
      await transports[0].send(bad);
    } on ApiFailure catch (e) {
      rejected = e.code == 'INVALID_STREAM_FRAME';
    }
    require(rejected, 'MALFORMED_FRAME_ACCEPTED');
    require(
      (await crypto(
        stores[0],
        'outbox',
      ))['messages'].any((m) => m['id'] == bad['id']) as bool,
      'OUTBOX_LOST',
    );
    mode.writeAsStringSync('pass');
    final retried = await transports[0].send(bad);
    require(
      retried['alreadyCommitted'] == true,
      'INVALID_ACK_RETRY_NOT_IDEMPOTENT',
    );
    await crypto(stores[0], 'saved', {
      'group': group,
      'id': bad['id'],
      'seq': retried['serverSequence'],
    });
    for (var index = 0; index < 2; index++) {
      var cursor =
          (await crypto(stores[index], 'cursor', {'group': group}))['cursor']
              as String;
      while (true) {
        final page = await transports[index].sync(group, cursor, limit: 2);
        final events = page['messages'] as List;
        for (var i = 0; i < events.length; i++) {
          final m = events[i] as Map;
          await crypto(stores[index], 'ingest', {
            'group': group,
            'id': m['clientMessageId'],
            'sender': m['senderDeviceId'],
            'seq': m['serverSequence'],
            'epoch': m['mlsEpoch'],
            'kind': m['envelopeKind'],
            'ciphertext': m['ciphertext'],
            'digest': m['ciphertextSha256'],
            'cursor': i == events.length - 1 ? page['nextCursor'] : '',
          });
        }
        cursor = page['nextCursor'] as String;
        if (page['hasMore'] != true) break;
      }
      final seq =
          (await crypto(stores[index], 'cursor', {'group': group}))['seq']
              as int;
      require(seq == sent.length, 'CURSOR_NOT_CONTIGUOUS');
      await transports[index].ack(group, seq);
      final timeline =
          (await crypto(stores[index], 'timeline', {
                'group': group,
              }))['messages']
              as List;
      require(
        timeline.length == sent.length &&
            timeline.map((m) => m['id']).toSet().containsAll(sent),
        'LOGICAL_DUP_OR_LOSS',
      );
    }
    stdout.writeln(
      'PASS: actual native Dart WSS/protobuf + Rust/OpenMLS/SQLCipher + TLS API/PG; half-open/blocked stream HTTPS fallback; lost durable ACK retries exact ciphertext once; WSS recovery; malformed ACK rejected with outbox retained; paginated decrypt/cursor/receipts; both clients contain all 8 IDs once. Not a GUI or GPRS timing run.',
    );
  } finally {
    mode.writeAsStringSync('pass');
    for (final t in transports) {
      t.close();
    }
    for (final http in clients) {
      http.close(force: true);
    }
    for (final store in stores) {
      store.dispose();
    }
    RustLib.dispose();
  }
}
