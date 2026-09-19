import 'package:actionnotes/ui/canvas_snap.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

Rect box(double left, double top, [double w = 100, double h = 80]) =>
    Rect.fromLTWH(left, top, w, h);

void main() {
  group('nothing to line up with', () {
    test('an empty canvas corrects nothing', () {
      expect(
        CanvasSnap.snap(moving: box(0, 0), others: const []).isEmpty,
        isTrue,
      );
    });

    test('a card far from everything is left alone', () {
      final result = CanvasSnap.snap(
        moving: box(500, 500),
        others: [box(0, 0)],
      );
      expect(result.correction, Offset.zero);
      expect(result.guides, isEmpty);
    });
  });

  group('lining up', () {
    test('a near-miss on the left edge is pulled onto it', () {
      final result = CanvasSnap.snap(moving: box(3, 300), others: [box(0, 0)]);
      expect(result.correction.dx, -3);
      expect(result.guides.single.vertical, isTrue);
      expect(result.guides.single.position, 0);
    });

    test('a centre line counts as much as an edge', () {
      // The moving card's centre is a hair off the other's centre.
      final result = CanvasSnap.snap(moving: box(48, 400), others: [box(0, 0)]);
      expect(result.correction.dx, closeTo(2, 0.001));
    });

    test('a card settles against the far side of its neighbour', () {
      // Its left edge is just past the other's right edge.
      final result = CanvasSnap.snap(
        moving: box(104, 300),
        others: [box(0, 0)],
      );
      expect(result.correction.dx, closeTo(-4, 0.001));
      expect(result.guides.single.position, 100);
    });

    test('the two axes are decided separately', () {
      // Lined up horizontally, nowhere near vertically.
      final result = CanvasSnap.snap(moving: box(2, 900), others: [box(0, 0)]);
      expect(result.correction.dx, -2);
      expect(result.correction.dy, 0);
      expect(result.guides.length, 1);
    });

    test('both axes can line up at once', () {
      final result = CanvasSnap.snap(moving: box(3, 4), others: [box(0, 0)]);
      expect(result.correction, const Offset(-3, -4));
      expect(result.guides.length, 2);
      expect(result.guides.where((g) => g.vertical).length, 1);
      expect(result.guides.where((g) => !g.vertical).length, 1);
    });

    test('the nearest alignment wins when several are in range', () {
      // Two candidates: 1 away and 5 away. The near one should win.
      final result = CanvasSnap.snap(
        moving: box(101, 500),
        others: [box(100, 0), box(106, 0)],
      );
      expect(result.correction.dx, closeTo(-1, 0.001));
    });

    test('exactly at the tolerance still counts, past it does not', () {
      expect(
        CanvasSnap.snap(
          moving: box(8, 500),
          others: [box(0, 0)],
          tolerance: 8,
        ).correction.dx,
        -8,
      );
      expect(
        CanvasSnap.snap(
          moving: box(9, 500),
          others: [box(0, 0)],
          tolerance: 8,
        ).correction.dx,
        0,
      );
    });
  });

  group('the guide that is drawn', () {
    test('runs between the two boxes it joins, not across the canvas', () {
      final result = CanvasSnap.snap(
        moving: box(2, 400, 100, 80),
        others: [box(0, 0, 100, 80)],
      );
      final guide = result.guides.single;
      expect(guide.from, 0);
      expect(guide.to, 480);
    });

    test('a horizontal guide spans the boxes sideways', () {
      final result = CanvasSnap.snap(
        moving: box(400, 2, 100, 80),
        others: [box(0, 0, 100, 80)],
      );
      final guide = result.guides.single;
      expect(guide.vertical, isFalse);
      expect(guide.from, 0);
      expect(guide.to, 500);
    });
  });
}
