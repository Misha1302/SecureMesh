import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:securemesh_client/session.dart';
import 'package:securemesh_client/delivery_client.dart';
import 'package:securemesh_client/src/rust/api.dart';
import 'package:securemesh_client/src/rust/frb_generated.dart';
import 'package:securemesh_client/transport.dart';

Future<void> main(List<String> args) async {
  final input = jsonDecode(File(args.single).readAsStringSync()) as Map;
  await RustLib.init(
    externalLibrary: ExternalLibrary.open(input['library'] as String),
  );
  final store = await NativeClient.open(
    path: input['path'] as String,
    passphrase: input['passphrase'] as String,
  );
  Future<Map<String, dynamic>> command(
    String op, [
    Map<String, dynamic> args = const {},
  ]) async =>
      jsonDecode(await store.execute(request: jsonEncode({'op': op, ...args})))
          as Map<String, dynamic>;
  var profile = await command('profile');
  final tls = SecurityContext(withTrustedRoots: true)
    ..setTrustedCertificates(input['cert'] as String);
  final http = HttpClient(context: tls);
  final session = AccountSession(
    http: http,
    endpoint: Uri.parse(profile['endpoint'] as String),
    profile: () => profile,
    prepareRefresh: () async =>
        (await command('refresh_prepare', {
              'endpoint': profile['endpoint'],
            }))['request']
            as Map<String, dynamic>,
    commitRefresh: (updated) async {
      profile =
          (await command('refresh_complete', {'response': updated}))['profile']
              as Map<String, dynamic>;
    },
  );
  MeshTransport? transport;
  NativeDelivery? delivery;
  try {
    if (input['reauthenticate'] == true) {
      final signedIn = session.reauthenticate(
        password: input['password'] as String,
        username: input['username'] as String?,
        command: command,
        commit: (tokens, account) async {
          profile =
              (await command('session_reauthenticate', {
                    'session': tokens,
                    'account': account,
                  }))['profile']
                  as Map<String, dynamic>;
        },
      );
      await Future.wait([
        signedIn,
        ...List.generate(8, (_) => session.request('/v1/users/me')),
      ]);
    }
    final result = await session.request('/v1/users/me') as Map;
    if (result['deviceId'] != input['device']) {
      throw StateError('DEVICE_CHANGED');
    }
    if (input['deliver'] == true) {
      transport = MeshTransport(
        endpoint: Uri.parse(profile['endpoint'] as String),
        device: profile['deviceId'] as String,
        token: () => profile['accessToken'] as String,
        http: http,
        https: (route, {data}) => session.request(route, data: data),
      );
      delivery = NativeDelivery(crypto: command, transport: transport);
      final clock = Stopwatch()..start();
      while (((await command('outbox'))['messages'] as List).isNotEmpty) {
        if (clock.elapsed > const Duration(seconds: 25)) {
          throw StateError('QUEUE_NOT_RECOVERED');
        }
        await delivery.tick(profile['group'] as String);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    stdout.writeln(jsonEncode({'ok': true}));
  } on ApiFailure catch (failure) {
    stdout.writeln(jsonEncode({'ok': false, 'code': failure.code}));
    exitCode = 2;
  } finally {
    delivery?.close();
    transport?.close();
    session.close();
    http.close(force: true);
    store.dispose();
    RustLib.dispose();
  }
}
