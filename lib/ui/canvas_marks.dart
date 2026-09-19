import 'dart:math' as math;
import 'dart:ui';

import '../models/canvas_layout.dart';

/// The geometry of the marks drawn on a canvas: where a shape is, and whether
/// a point is near enough to it to count as touching it.
///
/// Kept apart from the widget because it is arithmetic, not layout — it can be
/// reasoned about and tested without a screen, the way the snapping is.
class CanvasMarks {
  CanvasMarks._();

  /// How far apart to draw the background's marks, on the glass.
  ///
  /// A background drawn at one fixed scene spacing disappears twice over as
  /// you zoom out: the marks crowd together *and* each one shrinks. Doubling
  /// the scene spacing as the canvas shrinks — and halving it as it grows —
  /// keeps what lands on screen inside a band a person can actually see, so
  /// a background reads as a background at any zoom instead of as a faint
  /// tint at one end and a cage at the other.
  static const backgroundSpacing = 80.0;
  static const minOnScreen = 24.0;
  static const maxOnScreen = 160.0;

  static double backgroundStep(double scale) {
    if (scale <= 0 || !scale.isFinite) return 0;

    var spacing = backgroundSpacing;
    while (spacing * scale < minOnScreen && spacing < 1e9) {
      spacing *= 2;
    }
    while (spacing * scale > maxOnScreen && spacing > 1e-6) {
      spacing /= 2;
    }
    return spacing * scale;
  }

  static Offset pointAt(CanvasShape shape, int index) =>
      Offset(shape.points[index * 2], shape.points[index * 2 + 1]);

  static int pointCount(CanvasShape shape) => shape.points.length ~/ 2;

  /// The nine places an arrow can hold on to a card: its corners, the middles
  /// of its edges, and its centre.
  static const holds = [
    Offset(0, 0),
    Offset(0.5, 0),
    Offset(1, 0),
    Offset(0, 0.5),
    Offset(0.5, 0.5),
    Offset(1, 0.5),
    Offset(0, 1),
    Offset(0.5, 1),
    Offset(1, 1),
  ];

  /// Where on [card] a point is nearest to holding on, as a fraction of the
  /// card's box.
  static Offset nearestHold(Rect card, Offset point) {
    final at = Offset(
      card.width == 0 ? 0.5 : (point.dx - card.left) / card.width,
      card.height == 0 ? 0.5 : (point.dy - card.top) / card.height,
    );

    var best = holds.first;
    var bestDistance = double.infinity;
    for (final hold in holds) {
      final distance = (hold - at).distanceSquared;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = hold;
      }
    }
    return best;
  }

  /// Where a shape actually runs, now.
  ///
  /// The same as the points it was drawn with, except where an end is held to
  /// a card — then it is wherever that card is standing at this moment, which
  /// is what makes an arrow follow the thing it points at. A hold on a card
  /// that has gone falls back to where the arrow was drawn, rather than
  /// collapsing the arrow to nothing.
  static List<double> pointsOf(CanvasShape shape, Map<String, Rect> cards) {
    if (!shape.isStuck) return shape.points;

    final points = [...shape.points];
    void hold(CanvasAnchor? anchor, int index) {
      if (anchor == null) return;
      final card = cards[anchor.ref];
      if (card == null) return;
      points[index * 2] = card.left + card.width * anchor.ax;
      points[index * 2 + 1] = card.top + card.height * anchor.ay;
    }

    hold(shape.from, 0);
    hold(shape.to, points.length ~/ 2 - 1);
    return points;
  }

  /// The box a shape occupies, which is what a drawing is clipped and fitted
  /// against.
  static Rect bounds(CanvasShape shape) {
    var rect = Rect.fromPoints(pointAt(shape, 0), pointAt(shape, 0));
    for (var i = 1; i < pointCount(shape); i++) {
      final point = pointAt(shape, i);
      rect = rect.expandToInclude(Rect.fromPoints(point, point));
    }
    return rect;
  }

  /// Whether [point] is within [reach] of the mark.
  ///
  /// A box and an ellipse are touched by their outline rather than their
  /// middle: they are drawn as outlines, so rubbing at the empty space inside
  /// one should rub out what is standing there, not the box round it.
  static bool touches(
    CanvasShape shape,
    Offset point,
    double reach, {
    Map<String, Rect> cards = const {},
  }) {
    final drawn = CanvasShape(kind: shape.kind, points: pointsOf(shape, cards));
    return _touches(drawn, point, reach);
  }

  static bool _touches(CanvasShape shape, Offset point, double reach) {
    switch (shape.kind) {
      case CanvasShapeKind.line:
      case CanvasShapeKind.arrow:
      case CanvasShapeKind.stroke:
        for (var i = 0; i < pointCount(shape) - 1; i++) {
          if (_nearSegment(
            point,
            pointAt(shape, i),
            pointAt(shape, i + 1),
            reach,
          )) {
            return true;
          }
        }
        return false;

      case CanvasShapeKind.rectangle:
        final rect = bounds(shape);
        if (!rect.inflate(reach).contains(point)) return false;
        return !rect.deflate(reach).contains(point);

      case CanvasShapeKind.oval:
        final rect = bounds(shape);
        final radiusX = math.max(rect.width / 2, 0.001);
        final radiusY = math.max(rect.height / 2, 0.001);
        final dx = (point.dx - rect.center.dx) / radiusX;
        final dy = (point.dy - rect.center.dy) / radiusY;
        final distance = math.sqrt(dx * dx + dy * dy);
        // How far off the outline the point is, turned back into pixels by
        // the smaller radius so a long thin ellipse is not easier to hit at
        // one end than the other.
        final slack = reach / math.min(radiusX, radiusY);
        return (distance - 1).abs() <= slack;
    }
  }

  /// Where along a line a point sits, as the index of the segment it is
  /// nearest and how far along that segment it falls.
  ///
  /// Used to put a new node exactly where it was asked for, rather than at
  /// the middle of the nearest segment: a node added somewhere other than
  /// where you clicked moves the line as you add it.
  static ({int segment, Offset at})? nearestOn(
    List<double> points,
    Offset point,
  ) {
    if (points.length < 4) return null;

    ({int segment, Offset at})? best;
    var bestDistance = double.infinity;

    for (var i = 0; i < points.length ~/ 2 - 1; i++) {
      final a = Offset(points[i * 2], points[i * 2 + 1]);
      final b = Offset(points[i * 2 + 2], points[i * 2 + 3]);
      final along = b - a;
      final lengthSquared = along.dx * along.dx + along.dy * along.dy;

      final t = lengthSquared == 0
          ? 0.0
          : (((point.dx - a.dx) * along.dx + (point.dy - a.dy) * along.dy) /
                    lengthSquared)
                .clamp(0.0, 1.0);
      final on = a + along * t;
      final distance = (point - on).distanceSquared;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = (segment: i, at: on);
      }
    }
    return best;
  }

  /// The points with a new node put in where [point] falls.
  ///
  /// Returns them unchanged when there is nowhere sensible to put one, so a
  /// caller can hand the result straight back without checking.
  static List<double> withNodeAt(List<double> points, Offset point) {
    final found = nearestOn(points, point);
    if (found == null) return points;

    return [
      ...points.take((found.segment + 1) * 2),
      found.at.dx,
      found.at.dy,
      ...points.skip((found.segment + 1) * 2),
    ];
  }

  /// The points with one node taken out.
  ///
  /// A line needs two ends, so the last two are never removed — a mark with
  /// one point is not a mark.
  static List<double> withoutNode(List<double> points, int node) {
    if (points.length <= 4) return points;
    if (node < 0 || node >= points.length ~/ 2) return points;
    return [...points.take(node * 2), ...points.skip(node * 2 + 2)];
  }

  /// The points with one node moved to [to].
  static List<double> withNodeAtIndex(
    List<double> points,
    int node,
    Offset to,
  ) {
    if (node < 0 || node >= points.length ~/ 2) return points;
    final moved = [...points];
    moved[node * 2] = to.dx;
    moved[node * 2 + 1] = to.dy;
    return moved;
  }

  /// The path a mark is drawn along, straight or smoothed.
  ///
  /// A smoothed line is a Catmull-Rom spline through its own points,
  /// converted to the cubics a path is made of. Two points with nothing
  /// between them have no curve to describe, so they are bowed the way a node
  /// editor bows a connection: the tangents leave sideways, which is what
  /// makes a noodle read as a cable rather than as a bent wire.
  static Path pathThrough(List<double> points, {required bool curved}) {
    final path = Path();
    final count = points.length ~/ 2;
    if (count < 2) return path;

    Offset at(int i) => Offset(points[i * 2], points[i * 2 + 1]);

    path.moveTo(at(0).dx, at(0).dy);

    if (!curved) {
      for (var i = 1; i < count; i++) {
        path.lineTo(at(i).dx, at(i).dy);
      }
      return path;
    }

    if (count == 2) {
      final a = at(0);
      final b = at(1);
      final reach = ((b.dx - a.dx).abs() / 2).clamp(40.0, 260.0);
      path.cubicTo(a.dx + reach, a.dy, b.dx - reach, b.dy, b.dx, b.dy);
      return path;
    }

    for (var i = 0; i < count - 1; i++) {
      final p0 = at(i == 0 ? 0 : i - 1);
      final p1 = at(i);
      final p2 = at(i + 1);
      final p3 = at(i + 2 >= count ? count - 1 : i + 2);

      path.cubicTo(
        p1.dx + (p2.dx - p0.dx) / 6,
        p1.dy + (p2.dy - p0.dy) / 6,
        p2.dx - (p3.dx - p1.dx) / 6,
        p2.dy - (p3.dy - p1.dy) / 6,
        p2.dx,
        p2.dy,
      );
    }
    return path;
  }

  static bool _nearSegment(Offset point, Offset a, Offset b, double reach) {
    final along = b - a;
    final lengthSquared = along.dx * along.dx + along.dy * along.dy;
    if (lengthSquared == 0) return (point - a).distance <= reach;

    final t =
        (((point.dx - a.dx) * along.dx + (point.dy - a.dy) * along.dy) /
                lengthSquared)
            .clamp(0.0, 1.0);
    return (point - (a + along * t)).distance <= reach;
  }
}
