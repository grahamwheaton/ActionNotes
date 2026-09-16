import 'dart:typed_data';

import 'package:actionnotes/storage/image_encoder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// A bottom-up 32-bit BMP, the shape the Windows clipboard hands over.
Uint8List windowsClipboardBitmap({int width = 4, int height = 3}) {
  final stride = width * 4;
  final pixels = BytesBuilder();

  // Rows are written bottom-up, so the first row in the file is the last row
  // of the picture. Red on the picture's top row, blue on the bottom.
  for (var row = height - 1; row >= 0; row--) {
    for (var x = 0; x < width; x++) {
      final top = row == 0;
      // BMP byte order is blue, green, red, alpha.
      pixels.add(top ? [0, 0, 255, 255] : [255, 0, 0, 255]);
    }
  }

  final body = pixels.toBytes();
  final out = BytesBuilder()
    ..add([0x42, 0x4D]) // 'BM'
    ..add(_le32(14 + 40 + body.length))
    ..add(_le32(0))
    ..add(_le32(14 + 40))
    ..add(_le32(40)) // BITMAPINFOHEADER
    ..add(_le32(width))
    ..add(_le32(height)) // positive: bottom-up
    ..add([1, 0]) // planes
    ..add([32, 0]) // bits per pixel
    ..add(_le32(0)) // BI_RGB
    ..add(_le32(body.length))
    ..add(_le32(0))
    ..add(_le32(0))
    ..add(_le32(0))
    ..add(_le32(0))
    ..add(body);

  assert(stride == width * 4);
  return out.toBytes();
}

List<int> _le32(int value) =>
    [value & 0xff, (value >> 8) & 0xff, (value >> 16) & 0xff, (value >> 24) & 0xff];

void main() {
  group('a pasted Windows bitmap', () {
    test('is re-encoded as a real PNG, not merely renamed', () {
      final result = ImageEncoder.prepare(
        'pasted-20260916T154213.png',
        windowsClipboardBitmap(),
      );

      expect(result.fileName, 'pasted-20260916T154213.png');
      // The magic bytes are what GitHub and Obsidian go by.
      expect(result.bytes.take(4), [0x89, 0x50, 0x4E, 0x47]);
    });

    test('keeps the picture the right way up', () {
      // A BMP's rows run bottom-up; getting this wrong is what made a pasted
      // photo appear upside down.
      final result = ImageEncoder.prepare('x.png', windowsClipboardBitmap());
      final decoded = img.decodePng(Uint8List.fromList(result.bytes))!;

      final top = decoded.getPixel(0, 0);
      final bottom = decoded.getPixel(0, decoded.height - 1);

      expect(top.r, 255, reason: 'the top row was red in the source');
      expect(top.b, 0);
      expect(bottom.b, 255, reason: 'the bottom row was blue in the source');
      expect(bottom.r, 0);
    });

    test('is very much smaller afterwards', () {
      final bitmap = windowsClipboardBitmap(width: 200, height: 200);
      final result = ImageEncoder.prepare('x.png', bitmap);

      expect(result.bytes.length, lessThan(bitmap.length ~/ 4));
    });
  });

  group('files picked from disk', () {
    test('a real PNG is passed through untouched', () {
      final png = img.encodePng(img.Image(width: 3, height: 3));
      final result = ImageEncoder.prepare('shot.png', png);

      expect(result.fileName, 'shot.png');
      expect(result.bytes, same(png));
    });

    test('a real JPEG keeps its own compression', () {
      final jpg = img.encodeJpg(img.Image(width: 3, height: 3));
      final result = ImageEncoder.prepare('photo.jpg', jpg);

      expect(result.fileName, 'photo.jpg');
      expect(result.bytes, same(jpg));
    });

    test('a mislabelled file is converted rather than trusted', () {
      // Named .png but actually a bitmap — exactly the bug being fixed.
      final result = ImageEncoder.prepare('claims.png', windowsClipboardBitmap());

      expect(result.bytes.take(2), [0x89, 0x50]);
    });

    test('a bitmap named .bmp becomes a PNG named .png', () {
      final result = ImageEncoder.prepare('shot.bmp', windowsClipboardBitmap());

      expect(result.fileName, 'shot.png');
      expect(result.bytes.take(2), [0x89, 0x50]);
    });
  });

  group('anything unreadable', () {
    test('is kept, not dropped, and named honestly', () {
      final junk = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final result = ImageEncoder.prepare('mystery.png', junk);

      expect(result.bytes, junk);
      expect(result.fileName, 'mystery.bin');
    });
  });
}
