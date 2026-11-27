import 'dart:io';
import 'dart:math';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import 'src/rust/frb_generated.dart';
import 'transport.dart';

ExternalLibrary _nativeLibrary() {
  if (Platform.isIOS) {
    return ExternalLibrary.process(iKnowHowToUseIt: true);
  }
  final override = Platform.environment['SECUREMESH_CRYPTO_LIB'];
  if (override != null && override.isNotEmpty) {
    return ExternalLibrary.open(override);
  }
  if (Platform.isAndroid) {
    return ExternalLibrary.open('libsecuremesh_crypto.so');
  }
  final executable = File(Platform.resolvedExecutable).parent;
  if (Platform.isLinux) {
    return ExternalLibrary.open(
      '${executable.path}/lib/libsecuremesh_crypto.so',
    );
  }
  if (Platform.isWindows) {
    return ExternalLibrary.open('${executable.path}/securemesh_crypto.dll');
  }
  throw UnsupportedError('SecureMesh native core is unavailable on this OS.');
}

Future<void>? _bridge;
Future<void> initializeNativeBridge() async {
  final pending = _bridge ??= RustLib.init(externalLibrary: _nativeLibrary());
  try {
    await pending;
  } catch (_) {
    _bridge = null;
    rethrow;
  }
}

String newUuid() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  return uuidString(bytes);
}

HttpClient nativeHttpClient() {
  final context = SecurityContext(withTrustedRoots: true);
  final cert = Platform.environment['SECUREMESH_CERT_FILE'];
  if (cert != null) context.setTrustedCertificates(cert);
  return HttpClient(context: context)
    ..connectionTimeout = const Duration(seconds: 12);
}
