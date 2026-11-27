import 'dart:convert';
import 'dart:io';

import 'package:securemesh_client/voice_wave.dart';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:securemesh_client/src/rust/api.dart';
import 'package:securemesh_client/src/rust/frb_generated.dart';

Future<Map<String, dynamic>> call(
  NativeClient store,
  String op,
  Map<String, dynamic> args,
) async =>
    jsonDecode(await store.execute(request: jsonEncode({'op': op, ...args})))
        as Map<String, dynamic>;

Future<void> main() async {
  final root = Directory.current.parent.parent;
  await RustLib.init(
    externalLibrary: ExternalLibrary.open(
      Platform.environment['SECUREMESH_CRYPTO_LIB'] ??
          '${root.path}/src/crypto_core/target/debug/libsecuremesh_crypto.so',
    ),
  );
  final directory = Directory('${root.path}/.local/dart-bridge-test')
    ..createSync(recursive: true);
  // Synthetic local passphrase, never written into the repository or logs.
  final pass =
      '${DateTime.now().microsecondsSinceEpoch}-bridge-only-test-unlock';
  final a = await NativeClient.open(
    path: '${directory.path}/a-${DateTime.now().microsecondsSinceEpoch}.db',
    passphrase: pass,
  );
  final b = await NativeClient.open(
    path: '${directory.path}/b-${DateTime.now().microsecondsSinceEpoch}.db',
    passphrase: pass,
  );
  final ai = await call(a, 'init', {'identity': 'dart-a'});
  final bi = await call(b, 'init', {'identity': 'dart-b'});
  await call(a, 'pin', {
    'identity': 'dart-b',
    'public_key': bi['public_key'],
    'confirmed': true,
  });
  await call(b, 'pin', {
    'identity': 'dart-a',
    'public_key': ai['public_key'],
    'confirmed': true,
  });
  const group = '4bd64a30-993c-43ef-b86e-daef1229fc0a';
  await call(a, 'create', {'group': group});
  final kp = await call(b, 'keypackage', {});
  final welcome = await call(a, 'add', {
    'group': group,
    'keypackage': kp['keypackage'],
  });
  await call(b, 'join', {'group': group, 'welcome': welcome['welcome']});
  final message = await call(a, 'queue', {
    'group': group,
    'id': '1f40e419-05b1-4378-9d48-b814363a0111',
    'text': 'Dart → Rust → MLS → Rust → Dart',
  });
  final decrypted = await call(b, 'process', {
    'group': group,
    'ciphertext': message['ciphertext'],
  });
  if (decrypted['text'] != 'Dart → Rust → MLS → Rust → Dart') {
    throw StateError('FFI plaintext mismatch');
  }
  bool rejected = false;
  try {
    await call(b, 'process', {
      'group': group,
      'ciphertext': message['ciphertext'],
    });
  } catch (_) {
    rejected = true;
  }
  if (!rejected) throw StateError('FFI replay accepted');
  const id = '1098f7d0-f0da-4690-8528-31d289efdae9';
  final samples = VoiceSamples()
    ..add(Uint8List.fromList(List<int>.generate(32000, (i) => i % 251)));
  final voice = samples.finish();
  final args = {'id': id, 'group': group};
  await call(a, 'attachment_prepare', {
    ...args,
    'name': 'voice-note.wav',
    'media': 'voice',
    'data': base64Encode(voice),
  });
  final sealed = await call(a, 'attachment_ciphertext', args);
  final messageWithVoice = await call(a, 'attachment_queue', args);
  final received = await call(b, 'process', {
    'group': group,
    'ciphertext': messageWithVoice['ciphertext'],
  });
  if (received['attachment']['media'] != 'voice' ||
      received['attachment']['key'] != null) {
    throw StateError('Invalid voice timeline descriptor');
  }
  final opened = await call(b, 'attachment_open', {
    ...args,
    'ciphertext': sealed['ciphertext'],
  });
  if (opened['data'] != base64Encode(voice) ||
      voiceDuration(base64Decode(opened['data'] as String)) !=
          const Duration(seconds: 1)) {
    throw StateError('Voice did not round-trip through the native library');
  }
  final video = await File('test/fixtures/camera-clip.mp4').readAsBytes();
  final videoArgs = {
    'id': '4c96510a-d90f-4725-a768-a692a91424ce',
    'group': group,
  };
  await call(a, 'attachment_prepare', {
    ...videoArgs,
    'name': 'video-message.mp4',
    'media': 'video',
    'data': base64Encode(video),
  });
  final videoBlob = await call(a, 'attachment_ciphertext', videoArgs);
  final envelope = await call(a, 'attachment_queue', videoArgs);
  final incoming = await call(b, 'process', {
    'group': group,
    'ciphertext': envelope['ciphertext'],
  });
  if (incoming['attachment']['media'] != 'video' ||
      incoming['attachment']['key'] != null) {
    throw StateError('Invalid video timeline descriptor');
  }
  final modified = base64Decode(videoBlob['ciphertext'] as String);
  modified[modified.length - 1] ^= 1;
  var corruptRejected = false;
  try {
    await call(b, 'attachment_open', {
      ...videoArgs,
      'ciphertext': base64Encode(modified),
    });
  } catch (_) {
    corruptRejected = true;
  }
  if (!corruptRejected) throw StateError('Corrupted video accepted');
  final openedVideo = await call(b, 'attachment_open', {
    ...videoArgs,
    'ciphertext': videoBlob['ciphertext'],
  });
  if (openedVideo['data'] != base64Encode(video)) {
    throw StateError('Video did not round trip');
  }
  a.dispose();
  b.dispose();
  stdout.writeln(
    'PASS: Dart flutter_rust_bridge 2.13.0 calls native OpenMLS/SQLCipher; two stores, Welcome, Unicode decrypt, replay deny, authenticated voice and video round trips, modified video denied. Platform: ${Platform.operatingSystem}.',
  );
  RustLib.dispose();
}
