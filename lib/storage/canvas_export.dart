import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../markdown/canvas_cards.dart';

/// One picture on its way out of the app.
class ExportedImage {
  const ExportedImage({required this.name, required this.bytes});

  final String name;
  final List<int> bytes;
}

/// Turning a canvas into something that can leave the app.
///
/// Kept apart from the screen so it can be reasoned about and tested without
/// one: what comes out of here is bytes, and where they are written is
/// somebody else's problem.
class CanvasExport {
  CanvasExport._();

  /// Whether this platform has somewhere to save a file that means anything
  /// to the person choosing it. A phone has no folder to put thirty pictures
  /// in, so the export is not offered there.
  static bool get canSaveFiles =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// A file name for the whole board, from the project and the section.
  static String fileNameFor(
    String projectTitle,
    String section, {
    required String extension,
  }) {
    final stem = '$projectTitle $section'
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
        .replaceAll(RegExp(r'\s+'), '-')
        .toLowerCase();
    return '${stem.isEmpty ? 'canvas' : stem}.$extension';
  }

  /// The pictures on a board, in the order the cards come in, named so that
  /// two cards using the same file do not overwrite each other.
  ///
  /// [bytesFor] is asked for each one and may answer null — a picture that
  /// cannot be fetched is left out rather than written as an empty file,
  /// which would look like an export that worked.
  static Future<List<ExportedImage>> imagesOf(
    List<CanvasCard> cards, {
    required Future<List<int>?> Function(String reference) bytesFor,
  }) async {
    final taken = <String>{};
    final out = <ExportedImage>[];

    for (final card in cards) {
      final path = card.imagePath;
      if (path == null) continue;

      final bytes = await bytesFor(path);
      if (bytes == null) continue;

      var name = path.split('/').last;
      if (taken.contains(name)) {
        final dot = name.lastIndexOf('.');
        final stem = dot > 0 ? name.substring(0, dot) : name;
        final extension = dot > 0 ? name.substring(dot) : '';
        var suffix = 2;
        while (taken.contains('$stem-$suffix$extension')) {
          suffix++;
        }
        name = '$stem-$suffix$extension';
      }

      taken.add(name);
      out.add(ExportedImage(name: name, bytes: bytes));
    }

    return out;
  }

  /// The whole board as a one-page PDF, at the size the board actually is.
  ///
  /// A picture of the arrangement rather than a document of its contents:
  /// what a canvas is for is where things sit relative to each other, and a
  /// list of its cards down a page would throw that away. The page is made
  /// the shape of the board so nothing is cropped and nothing is scaled to
  /// fit a paper size nobody asked for.
  static Future<Uint8List> pdfOf({
    required Uint8List board,
    required int width,
    required int height,
  }) async {
    final document = pw.Document();
    final image = pw.MemoryImage(board);

    document.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(
          width.toDouble(),
          height.toDouble(),
          marginAll: 0,
        ),
        build: (context) => pw.Image(image, fit: pw.BoxFit.contain),
      ),
    );

    return document.save();
  }

  /// How many of a board's cards are pictures, which is what "export all
  /// images" writes out.
  static int pictureCount(List<CanvasCard> cards) =>
      cards.where((card) => card.isImage).length;
}
