import 'package:actionnotes/storage/image_encoder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

List<int> jpegOf(int width, int height) => img.encodeJpg(
  img.Image(width: width, height: height)..clear(img.ColorRgb8(90, 140, 200)),
  quality: 92,
);

List<int> pngOf(int width, int height) => img.encodePng(
  img.Image(width: width, height: height)..clear(img.ColorRgb8(20, 20, 20)),
);

void main() {
  group('what a picture costs the repo', () {
    test('a photograph off a phone is brought down to a usable size', () {
      // Nothing in the app ever draws one at four thousand pixels, and git
      // keeps every version for good — so the full-size one is paid for
      // forever, including after it is deleted.
      final ready = ImageEncoder.prepare('photo.jpg', jpegOf(4000, 3000));
      final decoded = img.decodeImage(ready.bytes as dynamic)!;

      expect(decoded.width, ImageEncoder.maxEdge);
      expect(decoded.height, 1536, reason: 'the shape is kept');
      expect(ready.fileName, 'photo.jpg', reason: 'still a jpeg');
    });

    test('a tall picture is measured on its own long edge', () {
      final ready = ImageEncoder.prepare('tall.jpg', jpegOf(1200, 3600));
      final decoded = img.decodeImage(ready.bytes as dynamic)!;

      expect(decoded.height, ImageEncoder.maxEdge);
      expect(decoded.width, lessThan(ImageEncoder.maxEdge));
    });

    test('a screenshot stays a png rather than going fuzzy', () {
      final ready = ImageEncoder.prepare('shot.png', pngOf(3000, 2000));
      final decoded = img.decodeImage(ready.bytes as dynamic)!;

      expect(decoded.width, ImageEncoder.maxEdge);
      expect(ready.fileName, 'shot.png');
      // A PNG re-encoded as a JPEG comes back with fuzz around its text.
      expect(ready.bytes.first, 0x89, reason: 'still a png');
    });

    test('a picture already small enough is not touched at all', () {
      final original = jpegOf(800, 600);
      final ready = ImageEncoder.prepare('small.jpg', original);

      // Byte for byte: re-encoding would throw away its own compression for
      // nothing.
      expect(ready.bytes, same(original));
      expect(ready.fileName, 'small.jpg');
    });
  });
}
