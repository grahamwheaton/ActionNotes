import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// What an attachment should be called and what bytes to store for it.
class EncodedImage {
  const EncodedImage({required this.fileName, required this.bytes});

  final String fileName;
  final List<int> bytes;
}

/// Normalises an image before it goes into the repo.
///
/// The Windows clipboard hands over a device-independent bitmap, so pasting
/// produced multi-megabyte BMP files carrying a `.png` name. GitHub and
/// Obsidian both go by the extension, so those images rendered nowhere but in
/// this app, and a BMP's rows run bottom-up, which is why a pasted photo
/// appeared upside down. Re-encoding to real PNG fixes all three at once and
/// takes a 7 MB paste down to a few hundred kilobytes.
class ImageEncoder {
  ImageEncoder._();

  /// Formats that are already fine to store as they are.
  static const _passThrough = {'png', 'jpg', 'jpeg', 'gif', 'webp'};

  /// The longest edge a stored picture may have.
  ///
  /// A phone camera hands over something like 4000 pixels across and four or
  /// five megabytes. Nothing in the app ever draws a picture at that size —
  /// a canvas card is a few hundred pixels — and git keeps every version of
  /// every file for good, so a photo dropped in and deleted still costs its
  /// space for the life of the repo. Two thousand is more than any screen
  /// here will use and cuts a typical photo by about four fifths.
  static const maxEdge = 2048;

  static EncodedImage prepare(String fileName, List<int> bytes) {
    final extension = _extensionOf(fileName);
    final known =
        _passThrough.contains(extension) && _looksLike(extension, bytes);

    // Measured rather than guessed at from the file size. A screenshot is
    // mostly flat colour, so a three-thousand-pixel one can weigh less than
    // a small photograph — any rule based on bytes lets exactly the pictures
    // this is meant for straight through.
    final decoded = img.decodeImage(_asBytes(bytes));

    // A file with a sound extension that is not oversized is left exactly as
    // it is, so its own compression is not thrown away by a re-encode.
    if (known && (decoded == null || !_tooBig(decoded))) {
      return EncodedImage(fileName: fileName, bytes: bytes);
    }

    if (decoded != null && known) {
      // Kept in the format it arrived in: a screenshot re-encoded as a JPEG
      // comes back with fuzz around its text, and a photograph turned into
      // a PNG comes back several times larger than it went in.
      final smaller = _shrink(decoded);
      return EncodedImage(
        fileName: fileName,
        bytes: extension == 'png'
            ? img.encodePng(smaller)
            : img.encodeJpg(smaller, quality: 88),
      );
    }

    if (decoded == null) {
      // Not something we can read; store it untouched rather than lose it,
      // but name it for what it is so nothing claims it is a PNG.
      return EncodedImage(
        fileName: _rename(fileName, _sniff(bytes) ?? 'bin'),
        bytes: bytes,
      );
    }

    final ready = _tooBig(decoded) ? _shrink(decoded) : decoded;
    return EncodedImage(
      fileName: _rename(fileName, 'png'),
      bytes: img.encodePng(ready),
    );
  }

  static bool _tooBig(img.Image image) =>
      image.width > maxEdge || image.height > maxEdge;

  static img.Image _shrink(img.Image image) => img.copyResize(
    image,
    width: image.width >= image.height ? maxEdge : null,
    height: image.height > image.width ? maxEdge : null,
    interpolation: img.Interpolation.average,
  );

  static Uint8List _asBytes(List<int> bytes) =>
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

  static String _extensionOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
  }

  static String _rename(String fileName, String extension) {
    final dot = fileName.lastIndexOf('.');
    final stem = dot <= 0 ? fileName : fileName.substring(0, dot);
    return '$stem.$extension';
  }

  /// Reads the magic bytes, so a mislabelled file is caught rather than
  /// trusted.
  static String? _sniff(List<int> bytes) {
    if (bytes.length < 4) return null;
    if (bytes[0] == 0x89 && bytes[1] == 0x50) return 'png';
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) return 'jpg';
    if (bytes[0] == 0x47 && bytes[1] == 0x49) return 'gif';
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) return 'bmp';
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45) {
      return 'webp';
    }
    return null;
  }

  static bool _looksLike(String extension, List<int> bytes) {
    final sniffed = _sniff(bytes);
    if (sniffed == null) return false;
    if (extension == 'jpeg') return sniffed == 'jpg';
    return sniffed == extension;
  }
}
