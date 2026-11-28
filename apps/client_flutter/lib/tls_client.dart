import 'dart:io';

/// A timed-out TLS handshake can finish after HttpClient has discarded its
/// connection task. Close the resulting socket before it loses its owner.
HttpClient meshTlsClient(
  SecurityContext context, {
  Duration connectionTimeout = const Duration(seconds: 30),
}) {
  final client = HttpClient(context: context)
    ..connectionTimeout = connectionTimeout;
  client.connectionFactory = (uri, proxyHost, proxyPort) async {
    if (proxyHost != null) {
      // HttpClient performs CONNECT and the subsequent TLS verification.
      return Socket.startConnect(proxyHost, proxyPort!);
    }
    if (uri.scheme != 'https') {
      throw ArgumentError('TLS_REQUIRED');
    }
    final task = await SecureSocket.startConnect(
      uri.host,
      uri.port,
      context: context,
    );
    var cancelled = false;
    final connection = task.socket.then((socket) {
      if (cancelled) {
        socket.destroy();
        throw const SocketException('TLS_CONNECTION_CANCELLED');
      }
      return socket;
    });
    return ConnectionTask.fromSocket(connection, () {
      cancelled = true;
      task.cancel();
    });
  };
  return client;
}
