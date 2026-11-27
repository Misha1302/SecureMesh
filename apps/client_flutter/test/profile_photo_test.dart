import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:securemesh_client/profile_photo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Legacy and malformed metadata never initiate a photo request', () {
    const group = '01234567-89ab-cdef-0123-456789abcdef';
    expect(peerPhotoRoute(group, null), isNull);
    expect(peerPhotoRoute(group, '../../settings'), isNull);
    expect(peerPhotoRoute('https://example.test/', group), isNull);
    expect(
      peerPhotoRoute(group, group),
      '/v1/conversations/$group/photo/$group',
    );
  });
  test(
    'RGB preview BMP decodes with the expected dimensions and channel order',
    () async {
      final rgb = Uint8List(photoSide * photoSide * 3);
      rgb[0] = 123;
      rgb[2] = 17;
      expect(await makeThumbnail(photoBitmap(rgb)), rgb);
      expect(() => photoPixels('AA=='), throwsFormatException);
      expect(() => photoBitmap(Uint8List(3)), throwsFormatException);
    },
  );
  test('Import crops the image centrally and strips source metadata', () async {
    final r = ui.PictureRecorder();
    final canvas = ui.Canvas(r);
    canvas.drawColor(const ui.Color(0xff00ff00), ui.BlendMode.src);
    canvas.drawRect(
      const ui.Rect.fromLTWH(24, 0, 48, 48),
      ui.Paint()..color = const ui.Color(0xffff0000),
    );
    final pic = r.endRecording();
    final img = await pic.toImage(96, 48);
    final png = (await img.toByteData(format: ui.ImageByteFormat.png))!;
    pic.dispose();
    img.dispose();
    final tile = await readPhoto(XFile.fromData(png.buffer.asUint8List()));
    expect(tile.length, 6912);
    expect(tile.sublist(3 * 24 * 48, 3 * 24 * 48 + 3), [255, 0, 0]);
  });
  testWidgets(
    'Selecting a photo needs explicit Save; removing clears only on Save',
    (tester) async {
      final rgb = Uint8List(photoSide * photoSide * 3);
      String? stored;
      var writes = 0;
      Future<dynamic> api(
        String route, {
        Map<String, dynamic>? data,
        String? method,
      }) async {
        expect(route, '/v1/users/me/photo');
        if (method == 'PUT') {
          writes++;
          stored = data!['pixels'] as String?;
          return {'photoVersion': 'fixture'};
        }
        return {'pixels': stored};
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showDialog<void>(
                context: ctx,
                builder: (_) => ProfilePhotoEditor(
                  api: api,
                  russian: false,
                  pick: () async => XFile.fromData(photoBitmap(rgb)),
                ),
              ),
              child: const Text('Edit'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Choose a photo'));
        for (
          var attempt = 0;
          attempt < 80 && find.text('Remove photo').evaluate().isEmpty;
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          await tester.pump();
        }
      });
      expect(find.text('Remove photo'), findsOneWidget);
      expect(writes, 0);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(stored, base64Encode(rgb));
      expect(writes, 1);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove photo'));
      await tester.pumpAndSettle();
      expect(writes, 1);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(stored, isNull);
      expect(writes, 2);
    },
  );
}
