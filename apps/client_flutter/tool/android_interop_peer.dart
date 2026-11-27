// Linux peer for the Android APK interoperability test. The two processes use
// independent encrypted databases and communicate via the production service.
import 'dart:convert';
import 'dart:io';

import 'package:securemesh_client/delivery_client.dart';
import 'package:securemesh_client/http_api.dart';
import 'package:securemesh_client/local_client.dart';
import 'package:securemesh_client/src/rust/api.dart';
import 'package:securemesh_client/src/rust/frb_generated.dart';
import 'package:securemesh_client/transport.dart';

Future<void> main() async {
  final fixture = jsonDecode(await stdin.transform(utf8.decoder).join()) as Map;
  await initializeNativeBridge();
  final store = await NativeClient.open(
    path: fixture['database'] as String,
    passphrase: fixture['passphrase'] as String,
  );
  Future<Map<String, dynamic>> crypto(
    String operation, [
    Map<String, dynamic> args = const {},
  ]) async => jsonDecode(
    await store.execute(request: jsonEncode({'op': operation, ...args})),
  ) as Map<String, dynamic>;

  final endpoint = Uri.parse(fixture['endpoint'] as String);
  final token = fixture['token'] as String;
  final group = fixture['group'] as String;
  final http = nativeHttpClient();
  final transport = MeshTransport(
    endpoint: endpoint,
    device: fixture['device'] as String,
    token: () => token,
    http: http,
    https: (route, {data}) =>
        meshHttp(http, endpoint, route, token: token, data: data),
  );
  final delivery = NativeDelivery(crypto: crypto, transport: transport);
  try {
    String? replyId;
    final deadline = DateTime.now().add(const Duration(minutes: 4));
    while (DateTime.now().isBefore(deadline)) {
      await delivery.tick(group);
      final events =
          (await crypto('timeline', {'group': group}))['messages'] as List;
      final received = events.where(
        (m) => m['own'] == false && m['text'] == fixture['challenge'],
      );
      if (received.length > 1) throw StateError('Duplicated Android message');
      if (replyId == null && received.length == 1) {
        replyId = newUuid();
        await crypto('queue', {
          'group': group,
          'id': replyId,
          'text': fixture['response'],
        });
      }
      if (replyId != null &&
          events.any(
            (m) =>
                m['id'] == replyId &&
                m['own'] == true &&
                m['status'] == 'delivered',
          )) {
        stdout.writeln(
          'PASS: Linux decrypted the Android message and received a peer receipt for its reply.',
        );
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw StateError(
      'Timed out waiting for Android challenge and reply receipt',
    );
  } finally {
    delivery.close();
    transport.close();
    http.close(force: true);
    store.dispose();
    RustLib.dispose();
  }
}
