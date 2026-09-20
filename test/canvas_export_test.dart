import 'package:actionnotes/markdown/canvas_cards.dart';
import 'package:actionnotes/storage/canvas_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('naming what comes out', () {
    test('a file is named after the project and the board', () {
      expect(
        CanvasExport.fileNameFor('House Move', 'Ideas', extension: 'pdf'),
        'house-move-ideas.pdf',
      );
    });

    test('punctuation somebody typed does not become a path', () {
      // A board called "Kitchen / Bathroom" must not try to write into a
      // folder called Kitchen.
      expect(
        CanvasExport.fileNameFor('A/B: c', 'x?', extension: 'pdf'),
        'ab-c-x.pdf',
      );
    });

    test('a board with no name still gets one', () {
      expect(
        CanvasExport.fileNameFor('', '', extension: 'pdf'),
        'canvas.pdf',
      );
    });
  });

  group('the pictures on a board', () {
    final cards = CanvasCards.parse(
      '- ![a](../attachments/trip/beach.png)\n'
      '- Some note\n'
      '- ![b](../attachments/other/beach.png)\n'
      '- ![c](../attachments/trip/hut.png)',
    );

    test('only the pictures, and the notes are left alone', () {
      expect(CanvasExport.pictureCount(cards), 3);
    });

    test('two pictures with the same name do not overwrite each other', () {
      // They come from different projects but land in one folder.
      final saved = <String>[];
      return CanvasExport.imagesOf(
        cards,
        bytesFor: (reference) async => [1, 2, 3],
      ).then((images) {
        saved.addAll(images.map((image) => image.name));
        expect(saved, ['beach.png', 'beach-2.png', 'hut.png']);
      });
    });

    test('one that cannot be fetched is left out, not written empty', () async {
      // An empty file looks exactly like an export that worked, which is the
      // one thing it must not look like.
      final images = await CanvasExport.imagesOf(
        cards,
        bytesFor: (reference) async =>
            reference.endsWith('hut.png') ? null : [1, 2, 3],
      );

      expect(images.map((image) => image.name), ['beach.png', 'beach-2.png']);
    });
  });
}
