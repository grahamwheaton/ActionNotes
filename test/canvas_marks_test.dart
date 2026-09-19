import 'dart:ui';

import 'package:actionnotes/models/canvas_layout.dart';
import 'package:actionnotes/ui/canvas_marks.dart';
import 'package:flutter_test/flutter_test.dart';

CanvasShape mark(CanvasShapeKind kind, List<double> points) =>
    CanvasShape(kind: kind, points: points);

void main() {
  _stickyArrows();

  group('what a mark covers', () {
    test('a line is touched along its length, not beside it', () {
      final line = mark(CanvasShapeKind.line, [0, 0, 100, 0]);

      expect(CanvasMarks.touches(line, const Offset(50, 0), 5), isTrue);
      expect(CanvasMarks.touches(line, const Offset(50, 4), 5), isTrue);
      expect(CanvasMarks.touches(line, const Offset(50, 40), 5), isFalse);
      // And not past either end, so rubbing beyond an arrow misses it.
      expect(CanvasMarks.touches(line, const Offset(140, 0), 5), isFalse);
    });

    test('a stroke is touched anywhere along its corners', () {
      final stroke = mark(CanvasShapeKind.stroke, [0, 0, 50, 0, 50, 50]);

      expect(CanvasMarks.touches(stroke, const Offset(25, 1), 5), isTrue);
      expect(CanvasMarks.touches(stroke, const Offset(50, 25), 5), isTrue);
      expect(CanvasMarks.touches(stroke, const Offset(10, 40), 5), isFalse);
    });

    test('a box is its outline, so the space inside it stays reachable', () {
      final box = mark(CanvasShapeKind.rectangle, [0, 0, 100, 100]);

      expect(CanvasMarks.touches(box, const Offset(50, 0), 5), isTrue);
      expect(CanvasMarks.touches(box, const Offset(0, 50), 5), isTrue);
      // The middle belongs to whatever is standing there, not to the box.
      expect(CanvasMarks.touches(box, const Offset(50, 50), 5), isFalse);
      expect(CanvasMarks.touches(box, const Offset(150, 50), 5), isFalse);
    });

    test('an oval is its outline too', () {
      final oval = mark(CanvasShapeKind.oval, [0, 0, 100, 100]);

      expect(CanvasMarks.touches(oval, const Offset(50, 0), 5), isTrue);
      expect(CanvasMarks.touches(oval, const Offset(50, 50), 5), isFalse);
      // A corner of the box it was drawn in is outside the ellipse itself.
      expect(CanvasMarks.touches(oval, const Offset(0, 0), 5), isFalse);
    });

    test('bounds cover every point of a stroke', () {
      final stroke = mark(CanvasShapeKind.stroke, [10, 90, 50, 20, 70, 60]);
      expect(CanvasMarks.bounds(stroke), const Rect.fromLTRB(10, 20, 70, 90));
    });
  });

  group('marks in the layout file', () {
    test('round-trip, and a canvas with none writes nothing extra', () {
      const plain = CanvasLayout(sections: {'Board': []});
      expect(plain.toJsonString(), isNot(contains('drawings')));

      final layout = plain.withDrawing('Board', [
        mark(CanvasShapeKind.arrow, [0, 0, 10, 10]),
        const CanvasShape(
          kind: CanvasShapeKind.oval,
          points: [1, 2, 3, 4],
          colour: CanvasColour.blue,
          thickness: 4,
        ),
      ]);

      final again = CanvasLayout.parse(layout.toJsonString());
      final shapes = again.drawingFor('Board');
      expect(shapes, hasLength(2));
      expect(shapes.first.kind, CanvasShapeKind.arrow);
      expect(shapes.last.colour, CanvasColour.blue);
      expect(shapes.last.thickness, 4);
    });

    test('a mark that cannot be understood is left out, not thrown', () {
      final again = CanvasLayout.parse(
        '{"sections": {"Board": []}, "drawings": {"Board": ['
        '{"k": "line", "p": [0, 0]},'
        '{"k": "line", "p": "nonsense"},'
        '{"k": "line", "p": [0, 0, 5, 5]}'
        ']}}',
      );
      expect(again.drawingFor('Board'), hasLength(1));
    });

    test('renaming a section carries its drawing, deleting it takes it', () {
      final layout = const CanvasLayout(sections: {'Board': []}).withDrawing(
        'Board',
        [
          mark(CanvasShapeKind.line, [0, 0, 5, 5]),
        ],
      );

      expect(
        layout.renameSection('Board', 'Wall').drawingFor('Wall'),
        hasLength(1),
      );
      expect(layout.withoutSection('Board').drawings, isEmpty);
    });

    test('emptying a drawing drops the entry', () {
      final layout = const CanvasLayout(sections: {'Board': []}).withDrawing(
        'Board',
        [
          mark(CanvasShapeKind.line, [0, 0, 5, 5]),
        ],
      );

      expect(layout.withDrawing('Board', const []).drawings, isEmpty);
    });
  });
}

void _stickyArrows() {
  group('an arrow held to a card', () {
    const card = Rect.fromLTWH(100, 100, 200, 100);

    test('holds at the nearest of nine places on it', () {
      expect(
        CanvasMarks.nearestHold(card, const Offset(100, 100)),
        Offset.zero,
      );
      expect(
        CanvasMarks.nearestHold(card, const Offset(300, 150)),
        const Offset(1, 0.5),
      );
      expect(
        CanvasMarks.nearestHold(card, const Offset(205, 155)),
        const Offset(0.5, 0.5),
      );
      expect(
        CanvasMarks.nearestHold(card, const Offset(295, 195)),
        const Offset(1, 1),
      );
    });

    test('follows the card when it moves', () {
      const arrow = CanvasShape(
        kind: CanvasShapeKind.arrow,
        points: [0, 0, 300, 150],
        to: CanvasAnchor(ref: 'door.png', ax: 1, ay: 0.5),
      );

      // Where it was drawn.
      expect(CanvasMarks.pointsOf(arrow, {'door.png': card}), [0, 0, 300, 150]);

      // The card moves a hundred to the right and fifty down, and the arrow's
      // point goes with it without the file being rewritten.
      expect(
        CanvasMarks.pointsOf(arrow, {
          'door.png': card.shift(const Offset(100, 50)),
        }),
        [0, 0, 400, 200],
      );
    });

    test('a hold on a card that has gone falls back to where it was drawn', () {
      const arrow = CanvasShape(
        kind: CanvasShapeKind.arrow,
        points: [0, 0, 300, 150],
        to: CanvasAnchor(ref: 'door.png', ax: 1, ay: 0.5),
      );

      expect(CanvasMarks.pointsOf(arrow, const {}), [0, 0, 300, 150]);
    });

    test('the eraser finds it where it is now, not where it was drawn', () {
      const arrow = CanvasShape(
        kind: CanvasShapeKind.arrow,
        points: [0, 0, 300, 150],
        to: CanvasAnchor(ref: 'door.png', ax: 1, ay: 0.5),
      );
      final moved = {'door.png': card.shift(const Offset(0, 400))};

      expect(
        CanvasMarks.touches(arrow, const Offset(150, 275), 6, cards: moved),
        isTrue,
      );
      expect(
        CanvasMarks.touches(arrow, const Offset(150, 75), 6, cards: moved),
        isFalse,
      );
    });

    test('the hold round-trips through the file', () {
      const layout = CanvasLayout(sections: {'Board': []});
      final saved = layout.withDrawing('Board', const [
        CanvasShape(
          kind: CanvasShapeKind.arrow,
          points: [0, 0, 10, 10],
          from: CanvasAnchor(ref: 'a', ax: 0.5, ay: 1),
          to: CanvasAnchor(ref: 'b', ax: 0, ay: 0.5),
        ),
      ]);

      final again = CanvasLayout.parse(
        saved.toJsonString(),
      ).drawingFor('Board').single;
      expect(again.from?.ref, 'a');
      expect(again.from?.ay, 1);
      expect(again.to?.ref, 'b');
      expect(again.to?.ax, 0);
    });
  });
}
