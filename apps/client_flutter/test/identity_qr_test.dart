import 'dart:convert';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/identity_qr.dart';
import 'package:securemesh_client/identity_comparison.dart';

void main() {
  testWidgets('a rendered local QR decodes to the complete fingerprint', (
    tester,
  ) async {
    final code = deviceFingerprint(base64Encode(List.generate(32, (i) => i)))!;
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      DeviceQr(code).paint(Canvas(recorder), const Size.square(320));
      final pic = recorder.endRecording();
      final image = await pic.toImage(320, 320);
      try {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        expect(
          await readIdentityImage(XFile.fromData(png!.buffer.asUint8List())),
          code.replaceAll(' ', ''),
        );
      } finally {
        image.dispose();
        pic.dispose();
      }
    });
  });
  testWidgets(
    'profile QR fills only a same-server username and cannot verify a device',
    (tester) async {
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        ProfileQr(
          'https://mesh.example',
          'alice_42',
        ).paint(Canvas(recorder), const Size.square(360));
        final pic = recorder.endRecording();
        final image = await pic.toImage(360, 360);
        try {
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          XFile file() => XFile.fromData(png!.buffer.asUint8List());
          expect(
            await readProfileImage(file(), 'https://mesh.example'),
            'alice_42',
          );
          await expectLater(
            readProfileImage(file(), 'https://other.example'),
            throwsFormatException,
          );
          await expectLater(readIdentityImage(file()), throwsFormatException);
        } finally {
          image.dispose();
          pic.dispose();
        }
      });
    },
  );

  testWidgets('comparison requires the independent code of the target device', (
    tester,
  ) async {
    final me = base64Encode(List.filled(32, 1)),
        peer = base64Encode(List.filled(32, 2));
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async {
              result = await compareDeviceKey(ctx, me, peer, (_, en) => en);
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final input = find.byType(TextField);
    await tester.enterText(input, deviceFingerprint(me)!);
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm'))
          .onPressed,
      isNull,
    );
    await tester.enterText(input, deviceFingerprint(peer)!);
    await tester.pump();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });
}
