// Run through the owned local integration fixture in tests/integration/public_channels.py.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/http_api.dart';
import 'package:securemesh_client/public_channels.dart';

class _FixtureHttp extends HttpOverrides {}

void main() {
  testWidgets(
    'Two native Flutter users publish and read through the hosted TLS API',
    (tester) async {
      final env = Platform.environment;
      final endpoint = Uri.parse(env['SECUREMESH_CHANNEL_FIXTURE_URL']!);
      expect(endpoint.scheme, 'https');
      expect(endpoint.host, '127.0.0.1');
      final tls = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(env['SECUREMESH_CHANNEL_FIXTURE_CA']!);
      final http = _FixtureHttp().createHttpClient(tls);
      addTearDown(() => http.close(force: true));
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<void> settle() async {
        for (var i = 0; i < 200; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (find.byType(LinearProgressIndicator).evaluate().isEmpty) return;
        }
        fail('Hosted channel operation timed out');
      }

      Future<void> asUser(String token) async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PublicChannels(
                api: (path, {data, method}) => meshHttp(
                  http,
                  endpoint,
                  path,
                  token: token,
                  data: data,
                  method: method,
                ),
                russian: false,
                close: () {},
              ),
            ),
          ),
        );
        await settle();
        expect(find.textContaining('Could not complete'), findsNothing);
      }

      Future<void> hit(String label) async {
        await tester.ensureVisible(find.text(label));
        await tester.tap(find.text(label));
        await tester.pump();
        await settle();
      }

      Finder chip(String reaction) => find.descendant(
        of: find.byTooltip(reaction),
        matching: find.byType(ChoiceChip),
      );

      Future<void> hitReaction(String reaction) async {
        final target = chip(reaction);
        await tester.ensureVisible(target);
        await tester.tap(target);
        await tester.pump();
        await settle();
      }

      Future<void> editVisiblePost(String body) async {
        await tester.ensureVisible(find.byTooltip('Post actions'));
        await tester.tap(find.byTooltip('Post actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Edit post'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.enterText(find.byType(TextFormField), body);
        await tester.tap(find.text('Save'));
        await tester.pump();
        await settle();
        await tester.pumpAndSettle();
      }

      final handle = 'ui_${DateTime.now().microsecondsSinceEpoch}';
      await asUser(env['SECUREMESH_CHANNEL_OWNER']!);
      await hit('New channel');
      await tester.enterText(
        find.widgetWithText(TextField, 'Channel title'),
        'Bulletin $handle',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Channel handle'),
        handle,
      );
      await hit('Create channel');
      expect(find.text('Public post'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Public post'),
        'An actual public-channel post.',
      );
      await hit('Publish');
      expect(find.text('An actual public-channel post.'), findsOneWidget);
      await asUser(env['SECUREMESH_CHANNEL_READER']!);
      await tester.enterText(find.byType(TextField), handle);
      await tester.tap(find.byTooltip('Search'));
      await tester.pump();
      await settle();
      await hit('Bulletin $handle');
      expect(find.text('Publish'), findsNothing);
      expect(find.text('An actual public-channel post.'), findsNothing);
      await hit('Subscribe');
      expect(find.text('An actual public-channel post.'), findsOneWidget);
      await hitReaction('Heart');
      expect(tester.widget<ChoiceChip>(chip('Heart')).selected, isTrue);
      expect(
        (tester.widget<ChoiceChip>(chip('Heart')).label as Text).data,
        '1',
      );
      await asUser(env['SECUREMESH_CHANNEL_OWNER']!);
      await hit('Bulletin $handle');
      await editVisiblePost('An edited public-channel post.');
      expect(find.text('An edited public-channel post.'), findsOneWidget);
      final editedTime = find.textContaining(
        RegExp(r'Edited .+ \d{1,2}:\d{2}'),
      );
      expect(editedTime, findsOneWidget);
      expect(
        (tester.widget<ChoiceChip>(chip('Heart')).label as Text).data,
        '1',
      );
      await asUser(env['SECUREMESH_CHANNEL_READER']!);
      await hit('Subscription feed');
      expect(find.text('An edited public-channel post.'), findsOneWidget);
      expect(editedTime, findsOneWidget);
      expect(tester.widget<ChoiceChip>(chip('Heart')).selected, isTrue);
      await hitReaction('Smile');
      expect(tester.widget<ChoiceChip>(chip('Heart')).selected, isFalse);
      expect(tester.widget<ChoiceChip>(chip('Smile')).selected, isTrue);
      await hitReaction('Smile');
      expect(tester.widget<ChoiceChip>(chip('Smile')).selected, isFalse);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await hit('Bulletin $handle');
      await hit('Unsubscribe');
      expect(find.text('An edited public-channel post.'), findsNothing);
      final restricted = '${handle}_in';
      final privateTitle = 'Invited $handle';
      await asUser(env['SECUREMESH_CHANNEL_OWNER']!);
      await hit('New channel');
      await tester.enterText(
        find.widgetWithText(TextField, 'Channel title'),
        privateTitle,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Channel handle'),
        restricted,
      );
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await hit('Create channel');
      expect(find.textContaining('server and subscribers'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Post for subscribers'),
        'Draft for the team.',
      );
      await hit('Publish');
      await editVisiblePost('Corrected for the team.');
      expect(find.text('Corrected for the team.'), findsOneWidget);
      await asUser(env['SECUREMESH_CHANNEL_READER']!);
      expect(find.text(privateTitle), findsNothing);
      await asUser(env['SECUREMESH_CHANNEL_OWNER']!);
      await hit(privateTitle);
      await tester.enterText(
        find.widgetWithText(TextField, 'Exact username'),
        env['SECUREMESH_CHANNEL_READER_USERNAME']!,
      );
      await hit('Invite');
      await asUser(env['SECUREMESH_CHANNEL_READER']!);
      await hit(privateTitle);
      expect(find.text('Corrected for the team.'), findsNothing);
      await hit('Accept invitation');
      expect(find.text('Corrected for the team.'), findsOneWidget);
      expect(find.byTooltip('Post actions'), findsNothing);
      await hit('Unsubscribe');
      expect(find.text(privateTitle), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
