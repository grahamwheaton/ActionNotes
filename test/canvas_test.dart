import 'package:actionnotes/markdown/canvas_cards.dart';
import 'package:actionnotes/markdown/canvas_placement.dart';
import 'package:actionnotes/models/canvas_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('cards in a section body', () {
    test('a bullet list is a list of cards', () {
      final cards = CanvasCards.parse('''
- ![door](../attachments/x/door.png)
- Some note text
- ![window](../attachments/x/window.png)
''');
      expect(cards.length, 3);
      expect(cards[0].isImage, isTrue);
      expect(cards[0].imagePath, '../attachments/x/door.png');
      expect(cards[1].isImage, isFalse);
      expect(cards[1].markdown, 'Some note text');
    });

    test('a card that runs to several lines stays one card', () {
      final cards = CanvasCards.parse('''
- A note
  that carries on
- Another
''');
      expect(cards.length, 2);
      expect(cards.first.markdown, 'A note\nthat carries on');
    });

    test('round-trips', () {
      const body = '- ![a](x.png)\n- A note\n  that carries on\n- Another';
      expect(CanvasCards.serialize(CanvasCards.parse(body)), body);
    });

    test('text before any bullet is kept as the first card', () {
      // A note turned into a canvas keeps what was already written in it.
      final cards = CanvasCards.parse('Already written\n\n- ![a](x.png)');
      expect(cards.first.markdown, 'Already written');
      expect(cards.last.isImage, isTrue);
    });

    test('an image with text beside it is a text card, not a picture', () {
      final cards = CanvasCards.parse('- ![a](x.png) and a caption');
      expect(cards.single.isImage, isFalse);
    });

    test('a hand-written star bullet reads the same as a dash', () {
      expect(CanvasCards.parse('* ![a](x.png)').single.isImage, isTrue);
    });
  });

  group('the layout file', () {
    test('round-trips through json', () {
      const layout = CanvasLayout(
        sections: {
          'Moodboard': [
            CanvasSpot(x: 10, y: 20, width: 300, z: 2, ref: 'door.png'),
          ],
        },
      );
      final again = CanvasLayout.parse(layout.toJsonString());
      expect(again.spotsFor('Moodboard').single.x, 10);
      expect(again.spotsFor('Moodboard').single.width, 300);
      expect(again.spotsFor('Moodboard').single.ref, 'door.png');
    });

    test('nonsense reads as no layout rather than throwing', () {
      expect(CanvasLayout.parse('not json at all').isEmpty, isTrue);
      expect(CanvasLayout.parse('[1,2,3]').isEmpty, isTrue);
      expect(CanvasLayout.parse('{"sections": 4}').isEmpty, isTrue);
    });

    test('it is what says a section is a canvas', () {
      const layout = CanvasLayout(sections: {'Moodboard': []});
      expect(layout.isCanvas('Moodboard'), isTrue);
      expect(layout.isCanvas('Notes'), isFalse);
    });

    test('renaming a section carries its canvas with it', () {
      const layout = CanvasLayout(
        sections: {
          'Moodboard': [CanvasSpot(x: 1, y: 2)],
        },
      );
      final renamed = layout.renameSection('Moodboard', 'References');
      expect(renamed.isCanvas('Moodboard'), isFalse);
      expect(renamed.spotsFor('References').single.x, 1);
    });
  });

  group('putting the positions back on the cards', () {
    List<CanvasCard> cardsOf(List<String> paths) => [
      for (final path in paths) CanvasCards.image(path),
    ];

    test('by index while nothing has moved', () {
      final cards = cardsOf(['a.png', 'b.png']);
      final placed = CanvasPlacement.place(cards, const [
        CanvasSpot(x: 10, y: 10, ref: 'a.png'),
        CanvasSpot(x: 20, y: 20, ref: 'b.png'),
      ]);
      expect(placed[0].x, 10);
      expect(placed[1].x, 20);
    });

    test('a card that shifted along keeps its place', () {
      // Something was inserted at the front on another device.
      final cards = cardsOf(['new.png', 'a.png', 'b.png']);
      final placed = CanvasPlacement.place(cards, const [
        CanvasSpot(x: 10, y: 10, ref: 'a.png'),
        CanvasSpot(x: 20, y: 20, ref: 'b.png'),
      ]);
      expect(placed[1].x, 10);
      expect(placed[2].x, 20);
    });

    test('a card with no position is put down where nothing else is', () {
      final cards = cardsOf(['a.png', 'new.png']);
      final placed = CanvasPlacement.place(cards, const [
        CanvasSpot(x: 40, y: 40, ref: 'a.png'),
      ]);
      expect(placed[1].x, isNot(40));
      expect(placed[1].z, greaterThan(placed[0].z));
    });

    test('a position whose card has gone is dropped, not left behind', () {
      final cards = cardsOf(['a.png']);
      final placed = CanvasPlacement.place(cards, const [
        CanvasSpot(x: 10, y: 10, ref: 'a.png'),
        CanvasSpot(x: 20, y: 20, ref: 'gone.png'),
      ]);
      expect(placed.length, 1);
      expect(placed.single.x, 10);
    });

    test('every card is placed, always', () {
      final cards = cardsOf(['a.png', 'b.png', 'c.png']);
      final placed = CanvasPlacement.place(cards, const []);
      expect(placed.length, 3);
      // And not all on top of each other.
      expect(placed.map((s) => '${s.x},${s.y}').toSet().length, 3);
    });

    test('a layout with no refs at all is still used, in order', () {
      // Written by hand, or by an older version that did not record them.
      final cards = cardsOf(['a.png', 'b.png']);
      final placed = CanvasPlacement.place(cards, const [
        CanvasSpot(x: 5, y: 5),
        CanvasSpot(x: 6, y: 6),
      ]);
      expect(placed[0].x, 5);
      expect(placed[1].x, 6);
      // And the refs are filled in on the way through, so next time it is
      // matched properly.
      expect(placed[0].ref, 'a.png');
    });
  });
}
