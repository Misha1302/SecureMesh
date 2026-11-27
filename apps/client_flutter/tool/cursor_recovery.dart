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

Future<void> main(List<String> args) async {
  final fixture = jsonDecode(File(args.single).readAsStringSync()) as Map;
  await RustLib.init(
    externalLibrary: ExternalLibrary.open(fixture['library'] as String),
  );
  final store = await NativeClient.open(
    path: fixture['path'] as String,
    passphrase: fixture['passphrase'] as String,
  );
  Future<Map<String, dynamic>> crypto(
    String op, [
    Map<String, dynamic> data = const {},
  ]) async =>
      jsonDecode(await store.execute(request: jsonEncode({'op': op, ...data})))
          as Map<String, dynamic>;
  final context = SecurityContext(withTrustedRoots: true)
    ..setTrustedCertificates(fixture['cert'] as String);
  final http = meshTlsClient(
    context,
    connectionTimeout: const Duration(seconds: 5),
  );
  var profile = Map<String, dynamic>.from(fixture['session'] as Map);
  final endpoint = Uri.parse(fixture['endpoint'] as String);
  final session = AccountSession(
    http: http,
    endpoint: endpoint,
    profile: () => profile,
    persist: (update) async {
      final next = {...profile, ...update};
      await crypto('profile_put', {'profile': next});
      profile = next;
    },
  );
  final transport = MeshTransport(
    endpoint: endpoint,
    device: fixture['device'] as String,
    token: () => profile['accessToken'] as String,
    http: http,
    https: (route, {data}) => session.request(route, data: data),
  );
  final delivery = NativeDelivery(crypto: crypto, transport: transport);
  final group = fixture['group'] as String,
      mode = File(fixture['mode'] as String);
  final ids = (fixture['ids'] as List).cast<String>();
  final clock = Stopwatch();
  var failures = 0, maxBeforeRestore = 0;
  final apiStatuses = <int>[];
  Future<Duration> tick() async {
    try {
      return (await delivery.tick(group)).delay;
    } on IOException {
      failures++;
    } on TimeoutException {
      failures++;
    } on ApiFailure catch (failure) {
      apiStatuses.add(failure.status);
      if (failure.status < 500 && failure.status != 429) {
        throw StateError('RECOVERY_API_${failure.status}');
      }
      failures++;
    }
    return const Duration(seconds: 2);
  }

  try {
    await transport.sync(group, '');
    stdout.writeln('WARM_READY');
    await stdout.flush();
    await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
    clock.start();
    while (true) {
      final delay = await tick();
      final events =
          (await crypto('history', {'group': group}))['events'] as List;
      if (mode.readAsStringSync() == 'offline') {
        if (events.length > maxBeforeRestore) maxBeforeRestore = events.length;
        if (events.isNotEmpty) throw StateError('BLACKOUT_DELIVERED_DATA');
      }
      if (events.length == ids.length) {
        final actual = events.map((e) => e['id']).toList();
        if (actual.toSet().length != ids.length ||
            jsonEncode(actual) != jsonEncode(ids)) {
          throw StateError('RECOVERY_ORDER_OR_DUPLICATE');
        }
        final cursor = await crypto('cursor', {'group': group});
        if (cursor['seq'] != ids.length ||
            (cursor['cursor'] as String).isEmpty) {
          throw StateError('CURSOR_NOT_DURABLE');
        }
        // Wait for the real processed receipt after the last inbox/cursor commit.
        for (var i = 0; i < 40; i++) {
          await Future<void>.delayed(await tick());
        }
        final result = {
          'count': ids.length,
          'ids': ids,
          'duplicates': 0,
          'missing_ids': 0,
          'received_during_blackout': maxBeforeRestore,
          'cursor_sequence': cursor['seq'],
          'elapsed_seconds': clock.elapsedMilliseconds / 1000,
          'network_failures_observed': failures,
          'api_statuses_observed': apiStatuses,
        };
        File(fixture['output'] as String).writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(result)}\n',
        );
        stdout.writeln(
          'PASS: native 1000-event ordered cursor recovery; no delivery during blackout; local inbox and cursor committed before processed receipt.',
        );
        break;
      }
      if (clock.elapsed > const Duration(minutes: 5)) {
        throw TimeoutException('CURSOR_RECOVERY_WATCHDOG');
      }
      await Future<void>.delayed(delay);
    }
  } finally {
    delivery.close();
    transport.close();
    session.close();
    http.close(force: true);
    store.dispose();
    RustLib.dispose();
  }
}
