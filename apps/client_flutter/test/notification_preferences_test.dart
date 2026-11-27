import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/android_notifications.dart';
import 'package:securemesh_client/account_hub.dart';
import 'package:securemesh_client/linux_notifications.dart';
import 'package:securemesh_client/notification_preferences.dart';

void main() {
  test('mute and quiet deadline survive profile serialisation without affecting another user', () {
    final now = DateTime.utc(2026, 11, 27);
    final end = now.add(const Duration(hours: 8));
    final edited = const NotificationPreferences()
        .setMute('a', true)
        .quietUntil(end);
    final restored = NotificationPreferences.fromProfile(
      jsonDecode(jsonEncode({NotificationPreferences.key: edited.toJson()}))
          as Map,
    );
    expect(restored.allows('a', end), isFalse);
    expect(
      restored.allows('b', end.subtract(const Duration(milliseconds: 1))),
      isFalse,
    );
    expect(restored.allows('b', end), isTrue);
    expect(restored.setMute('a', false).allows('a', end), isTrue);
    expect(NotificationPreferences.fromProfile({}).allows('a', now), isTrue);
  });
  testWidgets(
    'Android bridge receives one redacted eligible signal; mixed pending chat mutes are reevaluated',
    (tester) async {
      final calls = <MethodCall>[];
      const channel = MethodChannel('securemesh/message_notifications');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return call.method == 'show' ? true : null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final now = DateTime.utc(2026, 11, 27);
      var prefs = const NotificationPreferences();
      final notice = LinuxNotifications(
        allowed: () => true,
        allowsGroup: (group) => prefs.allows(group, now),
        russian: () => true,
        availability: (_) {},
        bridge: const AndroidNotifications(),
      );
      prefs = prefs.setMute('first', true);
      notice.incoming('first');
      await tester.pump(const Duration(seconds: 2));
      expect(calls, isEmpty);
      prefs = prefs.setMute('first', false);
      notice.incoming('first');
      notice.incoming('second');
      prefs = prefs.setMute('first', true);
      await tester.pump(const Duration(seconds: 1));
      expect(calls.single.method, 'show');
      expect(
        calls.single.arguments,
        true,
      ); // Only the language goes to Android.
      notice.cancel();
      await tester.pump();
      calls.clear();
      notice.incoming('second');
      prefs = prefs.quietUntil(now.add(const Duration(days: 1)));
      await tester.pump(const Duration(seconds: 1));
      expect(calls, isEmpty);
      notice.cancel();
      await tester.pump();
    },
  );
  testWidgets('quiet-hours menu exposes finite durations and cancellation', (
    tester,
  ) async {
    Duration? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuietHoursTile(
            russian: false,
            preferences: const NotificationPreferences(),
            onChanged: (duration) => changed = duration,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Do not disturb'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('For 8 hours'));
    await tester.pumpAndSettle();
    expect(changed, const Duration(hours: 8));
    await tester.tap(find.text('Do not disturb'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn off'));
    await tester.pumpAndSettle();
    expect(changed, Duration.zero);
  });
  testWidgets('chat menu mutes and unmutes just its selected conversation', (
    tester,
  ) async {
    var profile = <String, dynamic>{
      'trustState': 'DEVICE_TRUSTED',
      'userId': 'me',
    };
    final writes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, rebuild) => AccountHub(
              russian: false,
              profile: profile,
              crypto: (_, [args = const {}]) async => {},
              api: (route, {data}) async => switch (route) {
                '/v1/users/me' => {
                  'trustState': 'DEVICE_TRUSTED',
                  'userId': 'me',
                },
                '/v1/conversations' => [
                  {'id': 'g1', 'peerName': 'alice'},
                  {'id': 'g2', 'peerName': 'bob'},
                ],
                _ => [],
              },
              saveProfile: (_) async {},
              openChat: (_, _, _, _) async {},
              onMute: (group, muted) async {
                writes.add(group);
                rebuild(
                  () => profile = {
                    ...profile,
                    NotificationPreferences.key:
                        NotificationPreferences.fromProfile(profile)
                            .setMute(group, muted)
                            .toJson(),
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> choose(String group, String title) async {
      await tester.tap(
        find.descendant(
          of: find.byKey(ValueKey('chat-$group')),
          matching: find.byTooltip('Chat actions'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
    }

    await choose('g1', 'Mute chat');
    expect(NotificationPreferences.fromProfile(profile).mutedGroups, {'g1'});
    await choose('g1', 'Unmute chat');
    expect(NotificationPreferences.fromProfile(profile).mutedGroups, isEmpty);
    expect(writes, ['g1', 'g1']);
    await tester.pumpWidget(const SizedBox());
  });
}
