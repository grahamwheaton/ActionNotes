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
