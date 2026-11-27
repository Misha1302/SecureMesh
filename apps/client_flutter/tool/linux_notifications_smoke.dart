// Run inside an isolated Linux session with an empty dunst notification history.
import 'dart:async';
import 'dart:io';

import 'package:securemesh_client/linux_notifications.dart';

void check(bool ok, String label) {
  if (!ok) throw StateError(label);
}

Future<void> main() async {
  const text = {
    'event': {'text': 'private test marker'},
  };
  check(isNewIncomingText(text, 1), 'new incoming text');
  for (final result in [
    {'duplicate': true},
    {
      'event': {'own': true},
    },
    {
      'event': {'epoch': 2},
    },
    {
      'event': {'type': 'receipt', 'text': 'private test marker'},
    },
    {
      'event': {'text': ''},
    },
  ]) {
    check(!isNewIncomingText(result, 1), 'only incoming text');
  }
  check(!isNewIncomingText(text, 3), 'exclude epoch operations');
  final backend = <bool>[];
  var background = true;
  final notifications = LinuxNotifications(
    allowed: () => background,
    russian: () => false,
    availability: backend.add,
  );
  await notifications.probe();
  check(backend.single, 'desktop service reachable');
  notifications.incoming();
  notifications.cancel();
  notifications.incoming();
  background = false;
  await Future<void>.delayed(const Duration(milliseconds: 1200));
  check(backend.length == 1, 'cancel and foreground suppressed');
  background = true;
  notifications.incoming();
  notifications.incoming();
  for (var i = 0; i < 60 && backend.length == 1; ++i) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  check(
    backend.length == 2 && backend.last,
    'system accepted one notification',
  );
  final close = await Process.run('dunstctl', ['close-all']);
  check(close.exitCode == 0, 'close isolated test notifications');
  final history = await Process.run('gdbus', [
    'call',
    '--session',
    '--dest',
    'org.freedesktop.Notifications',
    '--object-path',
    '/org/freedesktop/Notifications',
    '--method',
    'org.dunstproject.cmd0.NotificationListHistory',
  ]);
  check(history.exitCode == 0, 'read daemon history');
  final entries = history.stdout as String;
  check("'appname'".allMatches(entries).length == 1, 'single notification');
  check(
    entries.contains("'summary': <'SecureMesh'>") &&
        entries.contains("'body': <'New message'>") &&
        entries.contains("'appname': <'SecureMesh'>"),
    'generic content only',
  );
  stdout.writeln(
    'PASS: D-Bus service accepted one redacted notification; cancelled, foreground, duplicate, own and control events suppressed.',
  );
}
