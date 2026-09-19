import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// A line drawn while dragging, showing what a card has lined up with.
class SnapGuide {
  const SnapGuide({
    required this.vertical,
    required this.position,
    required this.from,
    required this.to,
  });

  /// True for a line down the screen, which is an alignment of x.
  final bool vertical;

  /// Where the line sits, in scene coordinates: an x for a vertical line, a
  /// y for a horizontal one.
  final double position;

  /// How far the line runs along the other axis — the two boxes it joins,
  /// rather than the whole canvas, so it says what lined up with what.
  final double from;
  final double to;

  @override
  bool operator ==(Object other) =>
      other is SnapGuide &&
      other.vertical == vertical &&
      other.position == position &&
      other.from == from &&
      other.to == to;

  @override
  int get hashCode => Object.hash(vertical, position, from, to);

  @override
  String toString() =>
      'SnapGuide(${vertical ? 'x' : 'y'}=$position, $from..$to)';
}

/// What a drag should be corrected by, and what to draw for it.
class SnapResult {
  const SnapResult({this.correction = Offset.zero, this.guides = const []});

  final Offset correction;
  final List<SnapGuide> guides;

  bool get isEmpty => correction == Offset.zero && guides.isEmpty;
}

/// Lines a dragged card up with the ones it is not dragging.
///
/// Three edges are candidates on each axis — the two sides and the middle —
/// which is what makes a card settle against its neighbour's edge or share its
/// centre line. The nearest alignment within the tolerance wins on each axis
/// independently, so a card can settle horizontally without being dragged
/// sideways vertically.
///
/// Pure geometry on purpose: this is the part most likely to be subtly wrong,
/// and it can be checked without a canvas on screen.
class CanvasSnap {
  CanvasSnap._();

  /// How near counts as lined up, in the canvas's own units. Callers divide
  /// their screen tolerance by the zoom, so it feels the same however far in
  /// or out you are.
  static const defaultTolerance = 8.0;

  static SnapResult snap({
    required Rect moving,
    required List<Rect> others,
    double tolerance = defaultTolerance,
  }) {
    if (others.isEmpty) return const SnapResult();

    final vertical = _bestAxis(
      moving: [moving.left, moving.center.dx, moving.right],
      others: others,
      edgesOf: (rect) => [rect.left, rect.center.dx, rect.right],
      tolerance: tolerance,
    );
    final horizontal = _bestAxis(
      moving: [moving.top, moving.center.dy, moving.bottom],
      others: others,
      edgesOf: (rect) => [rect.top, rect.center.dy, rect.bottom],
      tolerance: tolerance,
    );

    final guides = <SnapGuide>[];

    if (vertical != null) {
      final against = others[vertical.other];
      guides.add(
        SnapGuide(
          vertical: true,
          position: vertical.at,
          from: math.min(moving.top, against.top),
          to: math.max(moving.bottom, against.bottom),
        ),
      );
    }
    if (horizontal != null) {
      final against = others[horizontal.other];
      guides.add(
        SnapGuide(
          vertical: false,
          position: horizontal.at,
          from: math.min(moving.left, against.left),
          to: math.max(moving.right, against.right),
        ),
      );
    }

    return SnapResult(
      correction: Offset(vertical?.shift ?? 0, horizontal?.shift ?? 0),
      guides: guides,
    );
  }

  /// The nearest alignment on one axis, or null when nothing is near enough.
  static _Alignment? _bestAxis({
    required List<double> moving,
    required List<Rect> others,
    required List<double> Function(Rect) edgesOf,
    required double tolerance,
  }) {
    _Alignment? best;

    for (var other = 0; other < others.length; other++) {
      for (final edge in edgesOf(others[other])) {
        for (final mine in moving) {
          final shift = edge - mine;
          if (shift.abs() > tolerance) continue;
          if (best != null && shift.abs() >= best.shift.abs()) continue;
          best = _Alignment(shift: shift, at: edge, other: other);
        }
      }
    }
    return best;
  }
}

class _Alignment {
  const _Alignment({
    required this.shift,
    required this.at,
    required this.other,
  });

  /// How far the moving box has to go to line up.
  final double shift;

  /// Where the shared line is.
  final double at;

  /// Which of the others it lined up with, for drawing the guide between
  /// them.
  final int other;
}
