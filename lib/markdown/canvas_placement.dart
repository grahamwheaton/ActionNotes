import '../models/canvas_layout.dart';
import 'canvas_cards.dart';

/// Pairs a canvas's cards with the positions kept for them.
///
/// The two live in different files, so they can drift: someone edits the list
/// on GitHub, or two devices write the layout at different moments. This is
/// where that drift is absorbed, and the rule is that the markdown wins —
/// every card is placed, and a position with no card is dropped.
class CanvasPlacement {
  CanvasPlacement._();

  /// How far apart cards are put when they arrive without a position.
  static const _step = 40.0;
  static const _defaultWidth = 260.0;

  /// Positions for [cards], in the same order.
  ///
  /// Matched by index first, which is right while nothing has moved, and
  /// checked against what the position says it belonged to. A position whose
  /// `ref` does not match is looked for elsewhere in the list, so a card that
  /// shifted along keeps its place on the canvas. A card with nothing to match
  /// is laid down in free space rather than on top of the pile.
  static List<CanvasSpot> place(
    List<CanvasCard> cards,
    List<CanvasSpot> spots,
  ) {
    final placed = List<CanvasSpot?>.filled(cards.length, null);
    final taken = <int>{};

    // Pass one: the position at the same index, when it says it belongs here.
    for (var i = 0; i < cards.length; i++) {
      if (i >= spots.length) break;
      final spot = spots[i];
      if (spot.ref.isEmpty || spot.ref == cards[i].ref) {
        placed[i] = spot.copyWith(ref: cards[i].ref);
        taken.add(i);
      }
    }

    // Pass two: a card whose position has moved along the list.
    for (var i = 0; i < cards.length; i++) {
      if (placed[i] != null) continue;
      for (var j = 0; j < spots.length; j++) {
        if (taken.contains(j) || spots[j].ref.isEmpty) continue;
        if (spots[j].ref != cards[i].ref) continue;
        placed[i] = spots[j].copyWith(ref: cards[i].ref);
        taken.add(j);
        break;
      }
    }

    // Pass three: anything still without one is put down where nothing is.
    var nextZ = 0;
    for (final spot in placed) {
      if (spot != null && spot.z >= nextZ) nextZ = spot.z + 1;
    }

    var slot = 0;
    for (var i = 0; i < cards.length; i++) {
      if (placed[i] != null) continue;
      final offset = _freeSlot(placed, slot);
      slot = offset + 1;
      placed[i] = CanvasSpot(
        x: (offset % 4) * (_defaultWidth + _step) + _step,
        y: (offset ~/ 4) * (_defaultWidth + _step) + _step,
        width: _defaultWidth,
        z: nextZ++,
        ref: cards[i].ref,
      );
    }

    return [for (final spot in placed) spot!];
  }

  /// The first grid slot from [from] that nothing already sits on, so a card
  /// arriving on a busy canvas does not land underneath something.
  static int _freeSlot(List<CanvasSpot?> placed, int from) {
    for (var slot = from; slot < from + 200; slot++) {
      final x = (slot % 4) * (_defaultWidth + _step) + _step;
      final y = (slot ~/ 4) * (_defaultWidth + _step) + _step;
      final clash = placed.any(
        (spot) =>
            spot != null && (spot.x - x).abs() < 8 && (spot.y - y).abs() < 8,
      );
      if (!clash) return slot;
    }
    return from;
  }
}
