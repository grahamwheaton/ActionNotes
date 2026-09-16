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

  static EncodedImage prepare(String fileName, List<int> bytes) {
    final extension = _extensionOf(fileName);

    // A file picked from disk with a sound extension is left alone, so its
    // original compression is not thrown away by a re-encode.
    if (_passThrough.contains(extension) && _looksLike(extension, bytes)) {
      return EncodedImage(fileName: fileName, bytes: bytes);
    }

    final decoded = img.decodeImage(_asBytes(bytes));
    if (decoded == null) {
      // Not something we can read; store it untouched rather than lose it,
      // but name it for what it is so nothing claims it is a PNG.
      return EncodedImage(
        fileName: _rename(fileName, _sniff(bytes) ?? 'bin'),
        bytes: bytes,
      );
    }

    return EncodedImage(
      fileName: _rename(fileName, 'png'),
      bytes: img.encodePng(decoded),
    );
  }

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
