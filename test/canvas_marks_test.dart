import 'dart:math' as math;
import 'dart:ui';

import 'package:actionnotes/models/canvas_layout.dart';
import 'package:actionnotes/ui/canvas_marks.dart';
import 'package:flutter_test/flutter_test.dart';

CanvasShape mark(CanvasShapeKind kind, List<double> points) =>
    CanvasShape(kind: kind, points: points);

void main() {
  _arrowHeads();
  _ridingAFrame();
  _stickyArrows();
  _nodes();

  group('the background spacing', () {
    test('stays inside a band you can see, at any zoom', () {
      for (final scale in [0.02, 0.1, 0.25, 0.5, 1.0, 2.0, 4.0, 16.0]) {
        final step = CanvasMarks.backgroundStep(scale);
        expect(
          step,
          inInclusiveRange(CanvasMarks.minOnScreen, CanvasMarks.maxOnScreen),
          reason: 'at zoom $scale',
        );
      }
    });

    test('is the plain spacing while the canvas is at its own size', () {
      expect(CanvasMarks.backgroundStep(1), CanvasMarks.backgroundSpacing);
    });

    test('doubles the scene spacing as the canvas shrinks', () {
      // Zoomed to a quarter, 80 apart would land 20 apart on the glass — too
      // close to read — so the spacing steps up to 160 in the scene.
      expect(CanvasMarks.backgroundStep(0.25), 40);
      expect(CanvasMarks.backgroundStep(0.125), 40);
    });

    test('a nonsense zoom draws nothing rather than looping', () {
      expect(CanvasMarks.backgroundStep(0), 0);
      expect(CanvasMarks.backgroundStep(-1), 0);
      expect(CanvasMarks.backgroundStep(double.nan), 0);
    });
  });

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

/// Where a path has got to, a fraction of the way along it.
Offset _atFraction(Path path, double fraction) {
  final metric = path.computeMetrics().first;
  return metric.getTangentForOffset(metric.length * fraction)!.position;
}

void _nodes() {
  group('nodes along a mark', () {
    test('a new one lands where it was asked for, not at the middle', () {
      final points = [0.0, 0.0, 100.0, 0.0];
      final with_ = CanvasMarks.withNodeAt(points, const Offset(70, 6));

      // On the line at x=70, because a node that appears somewhere other than
      // where you clicked moves the line as you add it.
      expect(with_, [0, 0, 70, 0, 100, 0]);
    });

    test('goes into the segment it is nearest, keeping the order', () {
      final points = [0.0, 0.0, 100.0, 0.0, 100.0, 100.0];
      final with_ = CanvasMarks.withNodeAt(points, const Offset(104, 60));

      expect(with_, [0, 0, 100, 0, 100, 60, 100, 100]);
    });

    test('one can be taken out, but never the last two', () {
      final points = [0.0, 0.0, 50.0, 10.0, 100.0, 0.0];

      expect(CanvasMarks.withoutNode(points, 1), [0, 0, 100, 0]);
      // A mark needs two ends; one point is not a mark.
      expect(CanvasMarks.withoutNode([0.0, 0.0, 10.0, 10.0], 0), [
        0,
        0,
        10,
        10,
      ]);
      // And an index that is not there changes nothing.
      expect(CanvasMarks.withoutNode(points, 9), points);
    });

    test('one can be moved without disturbing the others', () {
      final points = [0.0, 0.0, 50.0, 0.0, 100.0, 0.0];
      expect(CanvasMarks.withNodeAtIndex(points, 1, const Offset(50, 40)), [
        0,
        0,
        50,
        40,
        100,
        0,
      ]);
      expect(CanvasMarks.withNodeAtIndex(points, 7, Offset.zero), points);
    });

    test('a mark with nowhere to put one is handed back unchanged', () {
      expect(CanvasMarks.withNodeAt([1.0, 2.0], Offset.zero), [1.0, 2.0]);
    });
  });

  group('a bendy mark', () {
    test('a held end meets its card perpendicular to the touched edge', () {
      const right = CanvasAnchor(ref: 'a', ax: 1, ay: 0.5);
      const top = CanvasAnchor(ref: 'b', ax: 0.5, ay: 0);
      const points = [0.0, 0.0, 180.0, 160.0];
      final path = CanvasMarks.pathThrough(points, curved: true,
        fromNormal: CanvasMarks.anchorNormal(right, const Offset(180, 160)),
        toNormal: CanvasMarks.anchorNormal(top, const Offset(-180, -160)),
      );
      final metric = path.computeMetrics().first;
      final start = metric.getTangentForOffset(0)!.vector;
      final end = metric.getTangentForOffset(metric.length)!.vector;
      expect(start.dx, greaterThan(0));
      expect(start.dy.abs(), lessThan(0.01));
      expect(end.dx.abs(), lessThan(0.01));
      expect(end.dy, greaterThan(0));
    });

    test('a straight one goes corner to corner and no further', () {
      final path = CanvasMarks.pathThrough([
        0.0,
        0.0,
        50.0,
        40.0,
        100.0,
        0.0,
      ], curved: false);

      expect(path.getBounds(), const Rect.fromLTRB(0, 0, 100, 40));
    });

    test('a bendy one with two ends leaves sideways, like a cable', () {
      const points = [0.0, 0.0, 200.0, 100.0];

      // A quarter of the way along, a straight line is already a quarter of
      // the way down. The noodle leaves its end horizontally, so at the same
      // point it has hardly dropped at all — that flat start is what makes it
      // read as a cable rather than a bent wire.
      expect(
        _atFraction(CanvasMarks.pathThrough(points, curved: true), 0.25).dy,
        lessThan(
          _atFraction(CanvasMarks.pathThrough(points, curved: false), 0.25).dy,
        ),
      );
      // And it stays within the span of its own ends, the way a node editor
      // draws one.
      expect(
        CanvasMarks.pathThrough(points, curved: true).getBounds().width,
        closeTo(200, 1),
      );
    });

    test('a tall bendy arrow leaves and arrives vertically', () {
      const points = [0.0, 0.0, 90.0, 220.0];
      final path = CanvasMarks.pathThrough(points, curved: true);
      final start = path.computeMetrics().first.getTangentForOffset(0)!;
      expect(start.vector.dx.abs(), lessThan(0.01));
      expect(CanvasMarks.tipAngle(points, curved: true), closeTo(1.5708, 0.01));
    });

    test('a bendy one still passes through every node it was given', () {
      final bendy = CanvasMarks.pathThrough([
        0.0,
        0.0,
        50.0,
        80.0,
        100.0,
        0.0,
      ], curved: true);

      // Its bounds reach the middle node, so the curve goes through it rather
      // than cutting the corner off.
      expect(bendy.getBounds().bottom, greaterThanOrEqualTo(80));
    });

    test('nothing to draw is an empty path rather than a crash', () {
      expect(
        CanvasMarks.pathThrough(const [], curved: true).getBounds(),
        Rect.zero,
      );
      expect(
        CanvasMarks.pathThrough([1.0, 2.0], curved: false).getBounds(),
        Rect.zero,
      );
    });
  });
}

void _arrowHeads() {
  group('an arrow head', () {
    test('is a fixed size on the glass, so it does not grow with the zoom', () {
      // Two arrows of very different lengths get the same head, because the
      // head is measured on the glass rather than in the scene.
      expect(CanvasMarks.headLength(400), 16);
      expect(CanvasMarks.headLength(60), 16);
    });

    test('is never bigger than a third of the arrow it is on', () {
      expect(CanvasMarks.headLength(30), 10);
      expect(CanvasMarks.headLength(12), 4);
    });

    test('a line too short to point is left without one', () {
      expect(CanvasMarks.headLength(1), 0);
      expect(CanvasMarks.headLength(0), 0);
    });

    test('a straight arrow points the way it was drawn', () {
      // Left to right is zero; straight down is a quarter turn.
      expect(
        CanvasMarks.tipAngle([0, 0, 100, 0], curved: false),
        closeTo(0, 0.01),
      );
      expect(
        CanvasMarks.tipAngle([0, 0, 0, 100], curved: false),
        closeTo(math.pi / 2, 0.01),
      );
    });

    test(
      'a bendy arrow points along the way it arrives, not along its ends',
      () {
        const points = [0.0, 0.0, 200.0, 100.0];

        // Straight, it arrives on the diagonal between its two ends.
        expect(
          CanvasMarks.tipAngle(points, curved: false),
          closeTo(math.atan2(100, 200), 0.01),
        );
        // Bent, it is a noodle: the tangents leave and arrive sideways, so it
        // comes in flat however far apart the ends are.
        expect(CanvasMarks.tipAngle(points, curved: true), closeTo(0, 0.05));
      },
    );

    test('an arrow that doubles back still points where it ends up', () {
      // Out to the right and back again: the head must follow the last
      // stretch, not the line from where it started.
      const points = [0.0, 0.0, 200.0, 0.0, 100.0, 0.0];

      expect(
        math.cos(CanvasMarks.tipAngle(points, curved: false)),
        lessThan(0),
      );
    });

    test('its length is measured along the path, so a curve is longer than '
        'the line between its ends', () {
      const points = [0.0, 0.0, 200.0, 100.0];

      expect(CanvasMarks.lengthOf(points, curved: false), closeTo(223.6, 1));
      expect(
        CanvasMarks.lengthOf(points, curved: true),
        greaterThan(CanvasMarks.lengthOf(points, curved: false)),
      );
    });
  });
}

void _ridingAFrame() {
  group('a mark inside a frame', () {
    const frame = Rect.fromLTWH(0, 0, 200, 200);

    test('counts as inside only when all of it is', () {
      expect(CanvasMarks.within([10, 10, 190, 190], frame), isTrue);
      // Crossing the frame is passing through it, not sitting in it —
      // dragging the frame should not tear the far end along.
      expect(CanvasMarks.within([10, 10, 400, 10], frame), isFalse);
      expect(CanvasMarks.within([300, 300, 400, 400], frame), isFalse);
    });

    test('a mark with nothing in it is not inside anything', () {
      expect(CanvasMarks.within(const [], frame), isFalse);
      expect(CanvasMarks.within(const [10, 10], frame), isFalse);
    });

    test('moves by exactly what the frame moved', () {
      expect(CanvasMarks.shifted([0, 0, 10, 20], const Offset(5, -5)), [
        5,
        -5,
        15,
        15,
      ]);
    });

    test('moving a stroke keeps every bend the same shape', () {
      const stroke = [0.0, 0.0, 10.0, 40.0, 30.0, 10.0];
      final moved = CanvasMarks.shifted(stroke, const Offset(100, 100));

      expect(
        CanvasMarks.bounds(
          CanvasShape(kind: CanvasShapeKind.stroke, points: moved),
        ),
        CanvasMarks.bounds(
          const CanvasShape(kind: CanvasShapeKind.stroke, points: stroke),
        ).shift(const Offset(100, 100)),
      );
    });
  });
}
