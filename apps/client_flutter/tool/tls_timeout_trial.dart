import 'dart:convert';
import 'dart:io';

import 'package:securemesh_client/tls_client.dart';

Future<void> main(List<String> args) async {
  final endpoint = Uri.parse(args[0]);
  final context = SecurityContext();
  if (args[2] != 'untrusted') context.setTrustedCertificates(args[1]);
  final client = meshTlsClient(
    context,
    connectionTimeout: args[2] == 'late'
        ? const Duration(milliseconds: 200)
        : const Duration(seconds: 3),
  );
  try {
    final request = await client.getUrl(endpoint);
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    if (args[2] != 'healthy' || response.statusCode != 200 || body != 'ok') {
      throw StateError('unexpected HTTPS response');
    }
  } on HandshakeException {
    if (args[2] != 'untrusted') rethrow;
  } on SocketException {
    if (args[2] != 'late') rethrow;
  } finally {
    client.close(force: true);
  }
}
