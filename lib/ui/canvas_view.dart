import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../markdown/canvas_cards.dart';
import '../models/canvas_layout.dart';
import '../state/app_state.dart';
import '../storage/attachment_store.dart';
import 'canvas_snap.dart';
import 'context_menu.dart';
import 'note_view.dart';
import 'touch_input.dart';

/// A canvas: pictures and notes laid out on a surface that pans and zooms.
///
/// The content is the section's markdown and the arrangement is the layout
/// file beside it, so what is drawn here is always the list that is in the
/// project — this view only decides where each thing sits.
class CanvasView extends StatefulWidget {
  const CanvasView({
    super.key,
    required this.slug,
    required this.section,
    required this.cards,
    required this.spots,
    required this.onChanged,
    this.onRemoveCard,
    this.onDuplicateCard,
    this.onOpenFullScreen,
    this.autofocus = false,
  });

  final String slug;
  final String section;
  final List<CanvasCard> cards;

  /// One per card, in the same order.
  final List<CanvasSpot> spots;

  /// Fires with the new positions when something is moved or resized.
  final ValueChanged<List<CanvasSpot>> onChanged;

  /// Takes a card off the canvas, which means off the section's markdown —
  /// null where that is not on offer.
  final void Function(int index)? onRemoveCard;

  /// Puts a copy of a card on the canvas, next to the original.
  final void Function(int index)? onDuplicateCard;

  /// Opens the canvas on a screen of its own. Null when it already is one.
  final VoidCallback? onOpenFullScreen;

  /// Takes the keyboard on its own, so the shortcuts work without clicking
  /// first. True on a screen of its own and false in the panel inside a
  /// project, where the composer is what typing belongs to.
  final bool autofocus;

  @override
  State<CanvasView> createState() => CanvasViewState();
}

class CanvasViewState extends State<CanvasView> {
  /// Where the scene's origin sits in the viewport, and how big it is drawn.
  Offset _pan = Offset.zero;
  double _scale = 1;

  static const _minScale = 0.1;
  static const _maxScale = 6.0;

  /// The card being dragged or resized, so it draws in front and the surface
  /// leaves the gesture alone.
  int? _active;

  /// Everything picked out. A set rather than one index, because moving six
  /// references together is most of what a canvas is for.
  final Set<int> _selection = {};

  /// The marquee being dragged out, in viewport coordinates, or null.
  Rect? _marquee;
  Offset? _marqueeFrom;

  /// Each card's box, for working out what a marquee caught. Read from the
  /// cards themselves rather than guessed at: a card's height follows its
  /// picture or its text and is not known here.
  final Map<int, GlobalKey> _cardKeys = {};

  /// Where each dragged card started, and how far the pointer has gone since.
  ///
  /// Kept apart from the cards' own positions so that snapping is not sticky:
  /// the drag accumulates untouched and the snap is worked out from it afresh
  /// each frame, so a card pulled onto a line lets go again when the pointer
  /// keeps moving rather than clinging to it.
  final Map<int, Offset> _dragFrom = {};
  Offset _dragRaw = Offset.zero;

  /// The lines to draw for whatever the drag is currently lined up with.
  List<SnapGuide> _guides = const [];

  /// How near counts as lined up, on screen. Divided by the zoom before it is
  /// used, so it feels the same however far in or out you are.
  static const _snapPixels = 8.0;

  /// Pan and scale as the current gesture started, for a pinch.
  Offset _panAtStart = Offset.zero;

  /// The pointer holding the middle button down, while it is panning.
  int? _middlePan;
  double _scaleAtStart = 1;
  Offset _focalAtStart = Offset.zero;

  late List<CanvasSpot> _spots = [...widget.spots];

  final _viewport = GlobalKey();

  @visibleForTesting
  double get debugScale => _scale;

  @visibleForTesting
  Offset get debugPan => _pan;
  final _focus = FocusNode();

  @override
  void didUpdateWidget(CanvasView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The project is the truth; adopt it unless this view is mid-drag, when
    // adopting would fight the finger.
    //
    // A different number of cards is adopted whatever is happening: the
    // markdown and the layout are two files written a moment apart, so a card
    // added or removed arrives here before its position does, and carrying on
    // with the old list would index past the end of it.
    if (widget.spots.length != _spots.length ||
        (_active == null && widget.spots != oldWidget.spots)) {
      _spots = [...widget.spots];
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _commit() => widget.onChanged([..._spots]);

  /// Whether a click should add to the selection rather than replace it.
  static bool get _additive =>
      HardwareKeyboard.instance.isControlPressed ||
      HardwareKeyboard.instance.isMetaPressed ||
      HardwareKeyboard.instance.isShiftPressed;

  /// Whether the space bar is down, which turns a drag into a pan the way it
  /// does in every tool that has both a marquee and a canvas.
  static bool get _panning => HardwareKeyboard.instance.logicalKeysPressed
      .contains(LogicalKeyboardKey.space);

  void _select(int index, {required bool additive}) {
    setState(() {
      if (!additive) {
        if (_selection.contains(index)) return;
        _selection
          ..clear()
          ..add(index);
        return;
      }
      if (!_selection.remove(index)) _selection.add(index);
    });
  }

  /// Scene coordinates for a point in the viewport.
  Offset _toScene(Offset viewportPoint) => (viewportPoint - _pan) / _scale;

  void _zoomAround(Offset focal, double factor) {
    final next = (_scale * factor).clamp(_minScale, _maxScale);
    if (next == _scale) return;
    // Keep whatever is under the pointer under the pointer.
    final scene = _toScene(focal);
    setState(() {
      _scale = next;
      _pan = focal - scene * _scale;
    });
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final box = _viewport.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;

    final focal = box.globalToLocal(event.position);
    // A wheel zooms, which is what a canvas is for. Shift scrolls sideways
    // and plain two-finger scrolling on a trackpad pans, so a trackpad still
    // behaves as a trackpad.
    if (HardwareKeyboard.instance.isShiftPressed) {
      setState(() => _pan += Offset(-event.scrollDelta.dy, 0));
      return;
    }
    _zoomAround(focal, event.scrollDelta.dy < 0 ? 1.12 : 1 / 1.12);
  }

  void _onScaleStart(ScaleStartDetails details) {
    _panAtStart = _pan;
    _scaleAtStart = _scale;
    _focalAtStart = details.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final next = (_scaleAtStart * details.scale).clamp(_minScale, _maxScale);
    // The point under the fingers when the gesture started stays under them.
    final scene = (_focalAtStart - _panAtStart) / _scaleAtStart;
    setState(() {
      _scale = next;
      _pan = details.localFocalPoint - scene * next;
    });
  }

  /// Puts everything on screen, which is the first thing wanted on opening a
  /// canvas that was arranged somewhere else.
  void fit() {
    final box = _viewport.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || _spots.isEmpty) return;

    var left = double.infinity;
    var top = double.infinity;
    var right = -double.infinity;
    var bottom = -double.infinity;
    for (final spot in _spots) {
      left = math.min(left, spot.x);
      top = math.min(top, spot.y);
      right = math.max(right, spot.x + spot.width);
      // Height is not known until a picture has loaded, so assume a square —
      // it only decides the starting zoom, and erring tall is kinder than
      // cutting the bottom off.
      bottom = math.max(bottom, spot.y + spot.width);
    }

    const margin = 40.0;
    final width = right - left + margin * 2;
    final height = bottom - top + margin * 2;
    if (width <= 0 || height <= 0) return;

    final scale = math
        .min(box.size.width / width, box.size.height / height)
        .clamp(_minScale, 1.0);

    setState(() {
      _scale = scale;
      _pan =
          Offset(
            (box.size.width - (right - left) * scale) / 2,
            (box.size.height - (bottom - top) * scale) / 2,
          ) -
          Offset(left, top) * scale;
    });
  }

  /// Raises everything in [indices], keeping their order among themselves so
  /// a group that was stacked stays stacked.
  void _bringToFront(Iterable<int> indices) {
    var top = 0;
    for (final spot in _spots) {
      if (spot.z > top) top = spot.z;
    }
    final ordered = indices.toList()
      ..sort((a, b) => _spots[a].z.compareTo(_spots[b].z));
    if (ordered.isEmpty) return;

    setState(() {
      for (final index in ordered) {
        _spots[index] = _spots[index].copyWith(z: ++top);
      }
    });
  }

  void _sendToBack(Iterable<int> indices) {
    var bottom = 0;
    for (final spot in _spots) {
      if (spot.z < bottom) bottom = spot.z;
    }
    final ordered = indices.toList()
      ..sort((a, b) => _spots[b].z.compareTo(_spots[a].z));
    if (ordered.isEmpty) return;

    setState(() {
      for (final index in ordered) {
        _spots[index] = _spots[index].copyWith(z: --bottom);
      }
    });
    _commit();
  }

  /// Moves the selected card by a pixel, or ten with shift, which is how a
  /// card is put exactly where the eye wants it.
  bool _nudge(Offset direction) {
    if (_selection.isEmpty) return false;
    final step = HardwareKeyboard.instance.isShiftPressed ? 10.0 : 1.0;
    setState(() {
      for (final index in _selection) {
        final spot = _spots[index];
        _spots[index] = spot.copyWith(
          x: spot.x + direction.dx * step,
          y: spot.y + direction.dy * step,
        );
      }
    });
    _commit();
    return true;
  }

  /// A card's size in canvas units.
  ///
  /// Read from the card itself, because a card's height follows its picture or
  /// its text and is not known here. A card that has not been laid out yet is
  /// treated as square, which only decides where a guide is drawn for one
  /// frame.
  Size _sceneSize(int index) {
    final render = _cardKeys[index]?.currentContext?.findRenderObject();
    final width = _spots[index].width;
    if (render is! RenderBox || !render.hasSize) return Size(width, width);
    return Size(width, render.size.height / _scale);
  }

  Rect _sceneRect(int index) {
    final spot = _spots[index];
    return Offset(spot.x, spot.y) & _sceneSize(index);
  }

  void _beginDrag(int index) {
    final moving = _selection.contains(index) ? _selection : {index};
    _dragFrom
      ..clear()
      // A locked card stays where it is even when it is part of what was
      // picked up, so a background held in place is not dragged off by a
      // group selection that happened to include it.
      ..addEntries(
        moving
            .where((at) => !_spots[at].locked)
            .map((at) => MapEntry(at, Offset(_spots[at].x, _spots[at].y))),
      );
    _dragRaw = Offset.zero;
  }

  void _endDrag() {
    _dragFrom.clear();
    _dragRaw = Offset.zero;
    if (_guides.isNotEmpty) setState(() => _guides = const []);
  }

  /// Moves [index], and everything selected with it — dragging one of a group
  /// takes the group, which is the point of picking several.
  void _moveBy(int index, Offset delta) {
    if (_dragFrom.isEmpty) _beginDrag(index);
    final moving = _dragFrom.keys.toList();
    if (moving.isEmpty) return;

    _dragRaw += Offset(delta.dx / _scale, delta.dy / _scale);

    // Where the drag would put things with nothing lining up.
    Rect? proposed;
    for (final at in moving) {
      final rect = (_dragFrom[at]! + _dragRaw) & _sceneSize(at);
      proposed = proposed == null ? rect : proposed.expandToInclude(rect);
    }

    // Alt turns it off, for the times a card belongs just off the line.
    final snap = proposed == null || HardwareKeyboard.instance.isAltPressed
        ? const SnapResult()
        : CanvasSnap.snap(
            moving: proposed,
            others: [
              for (var i = 0; i < _spots.length; i++)
                if (!_dragFrom.containsKey(i)) _sceneRect(i),
            ],
            tolerance: _snapPixels / _scale,
          );

    setState(() {
      for (final at in moving) {
        final from = _dragFrom[at]! + _dragRaw + snap.correction;
        _spots[at] = _spots[at].copyWith(x: from.dx, y: from.dy);
      }
      _guides = snap.guides;
    });
  }

  /// Turns a card so its rotation handle follows the pointer.
  ///
  /// The angle is measured from the card's centre on screen to where the
  /// pointer is, and the handle sits above the card, so straight up is nought
  /// degrees. Shift steps it in fifteens, which is how a row of references
  /// ends up at the same tilt rather than nearly.
  void _rotateTo(int index, Offset globalPoint) {
    if (_spots[index].locked) return;

    final render = _cardKeys[index]?.currentContext?.findRenderObject();
    if (render is! RenderBox || !render.hasSize) return;

    final centre = render.localToGlobal(render.size.center(Offset.zero));
    final away = globalPoint - centre;
    if (away.distance < 4) return;

    var degrees = math.atan2(away.dy, away.dx) * 180 / math.pi + 90;
    if (HardwareKeyboard.instance.isShiftPressed) {
      degrees = (degrees / 15).round() * 15;
    }
    degrees = (degrees % 360 + 360) % 360;

    setState(() => _spots[index] = _spots[index].copyWith(rotation: degrees));
  }

  void _resizeBy(int index, Offset delta) {
    if (_spots[index].locked) return;
    setState(() {
      final spot = _spots[index];
      _spots[index] = spot.copyWith(
        width: math.max(80, spot.width + delta.dx / _scale),
      );
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final box = _viewport.currentContext?.findRenderObject() as RenderBox?;
    final centre = box == null
        ? Offset.zero
        : Offset(box.size.width / 2, box.size.height / 2);

    switch (event.logicalKey) {
      case LogicalKeyboardKey.equal:
      case LogicalKeyboardKey.add:
        _zoomAround(centre, 1.2);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.minus:
        _zoomAround(centre, 1 / 1.2);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.digit0:
        setState(() => _scale = 1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyF:
        fit();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyZ:
        zoomToSelection();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        if (_selection.isEmpty) return KeyEventResult.ignored;
        setState(_selection.clear);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyA:
        if (!HardwareKeyboard.instance.isControlPressed &&
            !HardwareKeyboard.instance.isMetaPressed) {
          return KeyEventResult.ignored;
        }
        setState(() {
          _selection
            ..clear()
            ..addAll([for (var i = 0; i < widget.cards.length; i++) i]);
        });
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        return _nudge(const Offset(-1, 0))
            ? KeyEventResult.handled
            : KeyEventResult.ignored;
      case LogicalKeyboardKey.arrowRight:
        return _nudge(const Offset(1, 0))
            ? KeyEventResult.handled
            : KeyEventResult.ignored;
      case LogicalKeyboardKey.arrowUp:
        return _nudge(const Offset(0, -1))
            ? KeyEventResult.handled
            : KeyEventResult.ignored;
      case LogicalKeyboardKey.arrowDown:
        return _nudge(const Offset(0, 1))
            ? KeyEventResult.handled
            : KeyEventResult.ignored;
      case LogicalKeyboardKey.delete:
      case LogicalKeyboardKey.backspace:
        if (_selection.isEmpty || widget.onRemoveCard == null) {
          return KeyEventResult.ignored;
        }
        _removeSelection();
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final touch = TouchInput.isPrimary;

    _cardKeys.removeWhere((index, _) => index >= widget.cards.length);
    _selection.removeWhere(
      (index) => index >= widget.cards.length || index >= _spots.length,
    );

    // Drawn back to front, so the stacking order is what the z says. Clamped
    // to whichever list is shorter, because the cards and their positions are
    // two files and can be a frame apart.
    final drawable = math.min(widget.cards.length, _spots.length);
    final order = [for (var i = 0; i < drawable; i++) i]
      ..sort((a, b) => _spots[a].z.compareTo(_spots[b].z));

    return Focus(
      focusNode: _focus,
      autofocus: widget.autofocus,
      onKeyEvent: _onKey,
      child: Listener(
        // A pointer signal is a wheel or a trackpad, and never joins the
        // gesture arena, so it can sit above everything without taking
        // anything away from the cards.
        onPointerSignal: _onPointerSignal,
        // The middle button pans, and never joins the gesture arena, so it
        // works while the left button is drawing a marquee.
        onPointerDown: (event) {
          if (event.buttons & kMiddleMouseButton == 0) return;
          _middlePan = event.pointer;
        },
        onPointerMove: (event) {
          if (event.pointer != _middlePan) return;
          setState(() => _pan += event.delta);
        },
        onPointerUp: (event) {
          if (event.pointer == _middlePan) _middlePan = null;
        },
        onPointerCancel: (event) {
          if (event.pointer == _middlePan) _middlePan = null;
        },
        child: ClipRect(
          child: Stack(
            key: _viewport,
            clipBehavior: Clip.none,
            children: [
              // The surface, *behind* the cards rather than around them. As an
              // ancestor its scale recognizer beat every card to the gesture
              // and nothing could be dragged; as a sibling underneath, a
              // pointer that lands on a card is taken by the card and never
              // reaches here.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    _focus.requestFocus();
                    setState(_selection.clear);
                  },
                  // Under a finger, a drag pans and two fingers zoom. With a
                  // mouse, a drag draws a marquee unless space is held, and
                  // panning is the middle button, space and drag, or the
                  // wheel.
                  onScaleStart: touch ? _onScaleStart : null,
                  onScaleUpdate: touch ? _onScaleUpdate : null,
                  onPanStart: touch
                      ? null
                      : (details) {
                          _focus.requestFocus();
                          // Space held: this drag pans instead of selecting,
                          // and leaving the marquee unstarted is what the
                          // update below reads as "pan".
                          if (_panning) return;
                          _marqueeStart(details.localPosition);
                        },
                  onPanUpdate: touch
                      ? null
                      : (details) {
                          if (_marqueeFrom != null) {
                            _marqueeUpdate(details.localPosition);
                            return;
                          }
                          setState(() => _pan += details.delta);
                        },
                  onPanEnd: touch ? null : (_) => _marqueeEnd(),
                  child: CustomPaint(
                    painter: _GridPainter(
                      pan: _pan,
                      scale: _scale,
                      colour: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.5,
                      ),
                    ),
                  ),
                ),
              ),
              for (final index in order)
                _CardOnCanvas(
                  key: ValueKey(
                    'card-${widget.section}-'
                    '${widget.cards[index].ref}-$index',
                  ),
                  card: widget.cards[index],
                  spot: _spots[index],
                  pan: _pan,
                  scale: _scale,
                  slug: widget.slug,
                  cardKey: _cardKeys.putIfAbsent(index, GlobalKey.new),
                  selected: _selection.contains(index),
                  onGrab: () {
                    _focus.requestFocus();
                    _active = index;
                    _select(index, additive: _additive);
                    _beginDrag(index);
                    // Raise whatever is now selected, so a group picked up
                    // comes forward together rather than one of it.
                    _bringToFront(
                      _selection.contains(index) ? _selection : {index},
                    );
                  },
                  onMenu: (at) => _showCardMenu(index, at),
                  onMove: (delta) => _moveBy(index, delta),
                  onRotate: (at) => _rotateTo(index, at),
                  onResize: (delta) => _resizeBy(index, delta),
                  onRelease: () {
                    _active = null;
                    _endDrag();
                    _commit();
                  },
                ),
              for (final guide in _guides)
                Positioned.fromRect(
                  rect: _guideRect(guide),
                  child: IgnorePointer(
                    child: ColoredBox(color: theme.colorScheme.tertiary),
                  ),
                ),
              if (_marquee != null)
                Positioned.fromRect(
                  rect: _marquee!,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.12,
                        ),
                        border: Border.all(color: theme.colorScheme.primary),
                      ),
                    ),
                  ),
                ),
              if (_selection.length > 1)
                Positioned(
                  left: 8,
                  bottom: 8,
                  child: IgnorePointer(
                    child: Material(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(16),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Text(
                          '${_selection.length} selected',
                          style: theme.textTheme.labelMedium,
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned(
                right: 8,
                bottom: 8,
                child: _CanvasControls(
                  scale: _scale,
                  onOpenFullScreen: widget.onOpenFullScreen,
                  onZoomIn: () => _zoomAround(_centre(), 1.2),
                  onZoomOut: () => _zoomAround(_centre(), 1 / 1.2),
                  onFit: fit,
                  onReset: () => setState(() => _scale = 1),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Takes the selection off the canvas.
  ///
  /// Highest index first, because removing a card shifts everything after it
  /// along and a list of indices taken in the other order would delete the
  /// wrong cards.
  void _removeSelection() {
    final going = _selection.toList()..sort((a, b) => b.compareTo(a));
    setState(_selection.clear);
    for (final index in going) {
      widget.onRemoveCard?.call(index);
    }
  }

  // --- The marquee -------------------------------------------------------
  //
  // Dragging empty space with a mouse draws a box and picks up everything it
  // touches. Panning moves to the middle button, to space and drag, and to
  // the wheel, which is how a tool with both a marquee and a canvas is
  // usually driven. Under a finger a drag still pans: there is no second
  // button to move panning to, and a marquee is a mouse's gesture.

  void _marqueeStart(Offset at) {
    _marqueeFrom = at;
    setState(() => _marquee = Rect.fromPoints(at, at));
  }

  void _marqueeUpdate(Offset at) {
    final from = _marqueeFrom;
    if (from == null) return;
    setState(() => _marquee = Rect.fromPoints(from, at));
  }

  void _marqueeEnd() {
    final box = _marquee;
    _marqueeFrom = null;
    setState(() => _marquee = null);
    if (box == null || box.shortestSide < 4) return;

    final caught = <int>{};
    for (final entry in _cardKeys.entries) {
      final render = entry.value.currentContext?.findRenderObject();
      if (render is! RenderBox || !render.hasSize) continue;
      final at = render.localToGlobal(Offset.zero, ancestor: _viewportBox);
      if (box.overlaps(at & render.size)) caught.add(entry.key);
    }

    setState(() {
      if (!_additive) _selection.clear();
      _selection.addAll(caught);
    });
  }

  RenderBox? get _viewportBox =>
      _viewport.currentContext?.findRenderObject() as RenderBox?;

  /// Lines up everything in [targets] on one edge, or spreads them evenly.
  ///
  /// Unlike dragging, this asks for no tolerance: you have said which cards
  /// and which edge, so they go exactly there.
  void _align(Set<int> targets, _Align how) {
    if (targets.length < 2) return;
    final rects = {for (final at in targets) at: _sceneRect(at)};

    var bounds = rects.values.first;
    for (final rect in rects.values) {
      bounds = bounds.expandToInclude(rect);
    }

    setState(() {
      switch (how) {
        case _Align.left:
          for (final at in targets) {
            _spots[at] = _spots[at].copyWith(x: bounds.left);
          }
        case _Align.centreX:
          for (final at in targets) {
            _spots[at] = _spots[at].copyWith(
              x: bounds.center.dx - rects[at]!.width / 2,
            );
          }
        case _Align.right:
          for (final at in targets) {
            _spots[at] = _spots[at].copyWith(
              x: bounds.right - rects[at]!.width,
            );
          }
        case _Align.top:
          for (final at in targets) {
            _spots[at] = _spots[at].copyWith(y: bounds.top);
          }
        case _Align.middleY:
          for (final at in targets) {
            _spots[at] = _spots[at].copyWith(
              y: bounds.center.dy - rects[at]!.height / 2,
            );
          }
        case _Align.bottom:
          for (final at in targets) {
            _spots[at] = _spots[at].copyWith(
              y: bounds.bottom - rects[at]!.height,
            );
          }
        case _Align.spreadX:
          _spread(targets, rects, bounds, horizontally: true);
        case _Align.spreadY:
          _spread(targets, rects, bounds, horizontally: false);
      }
    });
    _commit();
  }

  /// Even gaps between the cards, leaving the outermost two where they are —
  /// which is what makes spreading a row predictable rather than a surprise.
  void _spread(
    Set<int> targets,
    Map<int, Rect> rects,
    Rect bounds, {
    required bool horizontally,
  }) {
    final order = targets.toList()
      ..sort((a, b) {
        final first = horizontally ? rects[a]!.left : rects[a]!.top;
        final second = horizontally ? rects[b]!.left : rects[b]!.top;
        return first.compareTo(second);
      });
    if (order.length < 3) return;

    var occupied = 0.0;
    for (final at in order) {
      occupied += horizontally ? rects[at]!.width : rects[at]!.height;
    }
    final gap =
        ((horizontally ? bounds.width : bounds.height) - occupied) /
        (order.length - 1);

    var next = horizontally ? bounds.left : bounds.top;
    for (final at in order) {
      _spots[at] = horizontally
          ? _spots[at].copyWith(x: next)
          : _spots[at].copyWith(y: next);
      next += (horizontally ? rects[at]!.width : rects[at]!.height) + gap;
    }
  }

  /// Lays cards out in tidy rows, in the order they are on the canvas.
  ///
  /// The tool this is borrowed from calls it optimising; it is the one action
  /// that turns a heap of references into something you can look at. Rows are
  /// filled left to right up to a width that keeps the whole thing roughly
  /// square, and each row is only as tall as its tallest card.
  void _pack(Set<int> targets) {
    if (targets.length < 2) return;

    final order = targets.toList()
      ..sort((a, b) {
        final first = _sceneRect(a);
        final second = _sceneRect(b);
        // Reading order, so packing keeps roughly the arrangement that was
        // there rather than shuffling everything.
        final rows = (first.top / 200).floor().compareTo(
          (second.top / 200).floor(),
        );
        return rows != 0 ? rows : first.left.compareTo(second.left);
      });

    const gap = 16.0;
    var area = 0.0;
    for (final at in order) {
      final rect = _sceneRect(at);
      area += (rect.width + gap) * (rect.height + gap);
    }
    final target = math.sqrt(area) * 1.1;

    var bounds = _sceneRect(order.first);
    for (final at in order) {
      bounds = bounds.expandToInclude(_sceneRect(at));
    }

    var x = bounds.left;
    var y = bounds.top;
    var rowHeight = 0.0;

    setState(() {
      for (final at in order) {
        final size = _sceneSize(at);
        if (x > bounds.left && x + size.width > bounds.left + target) {
          x = bounds.left;
          y += rowHeight + gap;
          rowHeight = 0;
        }
        _spots[at] = _spots[at].copyWith(x: x, y: y);
        x += size.width + gap;
        rowHeight = math.max(rowHeight, size.height);
      }
    });
    _commit();
  }

  /// Makes everything the width of the widest, or the narrowest.
  void _matchWidth(Set<int> targets, {required bool widest}) {
    if (targets.length < 2) return;
    var width = _spots[targets.first].width;
    for (final at in targets) {
      final theirs = _spots[at].width;
      width = widest ? math.max(width, theirs) : math.min(width, theirs);
    }
    _transform(targets, (spot) => spot.copyWith(width: width));
  }

  /// Fills the view with whatever is selected, or everything if nothing is.
  void zoomToSelection() {
    if (_selection.isEmpty) {
      fit();
      return;
    }
    final box = _viewportBox;
    if (box == null) return;

    var bounds = _sceneRect(_selection.first);
    for (final at in _selection) {
      bounds = bounds.expandToInclude(_sceneRect(at));
    }

    const margin = 48.0;
    final scale = math
        .min(
          box.size.width / (bounds.width + margin * 2),
          box.size.height / (bounds.height + margin * 2),
        )
        .clamp(_minScale, _maxScale);

    setState(() {
      _scale = scale;
      _pan =
          Offset(
            (box.size.width - bounds.width * scale) / 2,
            (box.size.height - bounds.height * scale) / 2,
          ) -
          bounds.topLeft * scale;
    });
  }

  void _showAlignMenu(Set<int> targets, Offset at) {
    showItemMenu(context, [
      ContextMenuAction(
        label: 'Align left',
        icon: Icons.align_horizontal_left,
        onSelected: () => _align(targets, _Align.left),
      ),
      ContextMenuAction(
        label: 'Align centres',
        icon: Icons.align_horizontal_center,
        onSelected: () => _align(targets, _Align.centreX),
      ),
      ContextMenuAction(
        label: 'Align right',
        icon: Icons.align_horizontal_right,
        onSelected: () => _align(targets, _Align.right),
      ),
      ContextMenuAction(
        label: 'Align tops',
        icon: Icons.align_vertical_top,
        onSelected: () => _align(targets, _Align.top),
      ),
      ContextMenuAction(
        label: 'Align middles',
        icon: Icons.align_vertical_center,
        onSelected: () => _align(targets, _Align.middleY),
      ),
      ContextMenuAction(
        label: 'Align bottoms',
        icon: Icons.align_vertical_bottom,
        onSelected: () => _align(targets, _Align.bottom),
      ),
      if (targets.length > 2) ...[
        ContextMenuAction(
          label: 'Spread across',
          icon: Icons.horizontal_distribute,
          onSelected: () => _align(targets, _Align.spreadX),
        ),
        ContextMenuAction(
          label: 'Spread down',
          icon: Icons.vertical_distribute,
          onSelected: () => _align(targets, _Align.spreadY),
        ),
      ],
      ContextMenuAction(
        label: 'Pack into rows',
        icon: Icons.grid_view,
        onSelected: () => _pack(targets),
      ),
      ContextMenuAction(
        label: 'Match the widest',
        icon: Icons.width_wide,
        onSelected: () => _matchWidth(targets, widest: true),
      ),
      ContextMenuAction(
        label: 'Match the narrowest',
        icon: Icons.width_normal,
        onSelected: () => _matchWidth(targets, widest: false),
      ),
    ], at);
  }

  void _transform(Set<int> targets, CanvasSpot Function(CanvasSpot) change) {
    setState(() {
      for (final at in targets) {
        if (_spots[at].locked && change(_spots[at]).locked) continue;
        _spots[at] = change(_spots[at]);
      }
    });
    _commit();
  }

  /// Moves cards one step through the stack rather than all the way.
  void _shuffle(Set<int> targets, {required bool forwards}) {
    final order = [for (var i = 0; i < _spots.length; i++) i]
      ..sort((a, b) => _spots[a].z.compareTo(_spots[b].z));

    final moving = forwards ? order.reversed.toList() : order;
    setState(() {
      for (final index in moving) {
        if (!targets.contains(index)) continue;
        final position = order.indexOf(index);
        final swapWith = forwards ? position + 1 : position - 1;
        if (swapWith < 0 || swapWith >= order.length) continue;
        final other = order[swapWith];
        if (targets.contains(other)) continue;

        final mine = _spots[index].z;
        _spots[index] = _spots[index].copyWith(z: _spots[other].z);
        _spots[other] = _spots[other].copyWith(z: mine);
        order[position] = other;
        order[swapWith] = index;
      }
    });
    _commit();
  }

  void _showCardMenu(int index, Offset at) {
    // Whatever is selected, or the card that was clicked if it is not part of
    // the selection.
    final targets = _selection.contains(index) ? {..._selection} : {index};
    final many = targets.length > 1;

    showItemMenu(context, [
      if (many)
        ContextMenuAction(
          label: 'Line ${targets.length} up…',
          icon: Icons.align_horizontal_left,
          onSelected: () => _showAlignMenu(targets, at),
        ),
      ContextMenuAction(
        label: many ? 'Bring ${targets.length} to front' : 'Bring to front',
        icon: Icons.flip_to_front,
        onSelected: () {
          _bringToFront(targets);
          _commit();
        },
      ),
      ContextMenuAction(
        label: many ? 'Send ${targets.length} to back' : 'Send to back',
        icon: Icons.flip_to_back,
        onSelected: () => _sendToBack(targets),
      ),
      ContextMenuAction(
        label: 'Forward one',
        icon: Icons.arrow_upward,
        onSelected: () => _shuffle(targets, forwards: true),
      ),
      ContextMenuAction(
        label: 'Back one',
        icon: Icons.arrow_downward,
        onSelected: () => _shuffle(targets, forwards: false),
      ),
      ContextMenuAction(
        label: 'Flip across',
        icon: Icons.swap_horiz,
        onSelected: () =>
            _transform(targets, (spot) => spot.copyWith(flipX: !spot.flipX)),
      ),
      ContextMenuAction(
        label: 'Flip down',
        icon: Icons.swap_vert,
        onSelected: () =>
            _transform(targets, (spot) => spot.copyWith(flipY: !spot.flipY)),
      ),
      if (targets.any((at) => _spots[at].rotation != 0))
        ContextMenuAction(
          label: 'Straighten',
          icon: Icons.rotate_left,
          onSelected: () =>
              _transform(targets, (spot) => spot.copyWith(rotation: 0)),
        ),
      ContextMenuAction(
        label: _spots[index].locked ? 'Unlock' : 'Lock in place',
        icon: _spots[index].locked ? Icons.lock_open : Icons.lock_outline,
        onSelected: () {
          final lock = !_spots[index].locked;
          setState(() {
            for (final at in targets) {
              _spots[at] = _spots[at].copyWith(locked: lock);
            }
          });
          _commit();
        },
      ),
      if (widget.onDuplicateCard != null)
        ContextMenuAction(
          label: many ? 'Duplicate ${targets.length}' : 'Duplicate',
          icon: Icons.copy_all_outlined,
          onSelected: () {
            // Highest first, so each insertion does not shift the ones still
            // to be copied.
            final order = targets.toList()..sort((a, b) => b.compareTo(a));
            for (final at in order) {
              widget.onDuplicateCard!(at);
            }
          },
        ),
      if (widget.onRemoveCard != null)
        ContextMenuAction(
          label: many ? 'Delete ${targets.length} cards' : 'Delete card',
          icon: Icons.delete_outline,
          destructive: true,
          onSelected: () {
            setState(() {
              _selection
                ..clear()
                ..addAll(targets);
            });
            _removeSelection();
          },
        ),
    ], at);
  }

  /// A guide as a hairline in the viewport.
  ///
  /// A rectangle a pixel wide rather than a painter, so it sits in the same
  /// stack as the cards and needs no second coordinate system to reason
  /// about.
  Rect _guideRect(SnapGuide guide) {
    final at = guide.position * _scale;
    final from = guide.from * _scale;
    final to = guide.to * _scale;

    return guide.vertical
        ? Rect.fromLTWH(at + _pan.dx, from + _pan.dy, 1, to - from)
        : Rect.fromLTWH(from + _pan.dx, at + _pan.dy, to - from, 1);
  }

  Offset _centre() {
    final box = _viewport.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return Offset.zero;
    return Offset(box.size.width / 2, box.size.height / 2);
  }
}

/// One card, placed and scaled.
///
/// Positioned in viewport coordinates rather than inside a scaled Stack, so a
/// card's text stays crisp at any zoom and its own gestures arrive unscaled.
/// The ways a group of cards can be lined up.
enum _Align { left, centreX, right, top, middleY, bottom, spreadX, spreadY }

class _CardOnCanvas extends StatelessWidget {
  const _CardOnCanvas({
    super.key,
    required this.card,
    required this.spot,
    required this.pan,
    required this.scale,
    required this.slug,
    required this.selected,
    required this.cardKey,
    required this.onGrab,
    required this.onMenu,
    required this.onMove,
    required this.onRotate,
    required this.onResize,
    required this.onRelease,
  });

  final CanvasCard card;
  final CanvasSpot spot;
  final Offset pan;
  final double scale;
  final String slug;
  final bool selected;

  /// On the card's own box, so a marquee can ask where it actually is — a
  /// card's height follows its picture or its text and is not known anywhere
  /// else.
  final GlobalKey cardKey;
  final VoidCallback onGrab;

  /// Right-clicked, or held on a phone: the card's own menu, at the pointer.
  final ValueChanged<Offset> onMenu;
  final ValueChanged<Offset> onMove;

  /// Where the rotation handle has been dragged to, in global coordinates —
  /// the angle is worked out against the card's centre by the canvas, which
  /// is the only place that knows where that is on screen.
  final ValueChanged<Offset> onRotate;
  final ValueChanged<Offset> onResize;
  final VoidCallback onRelease;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final at = Offset(spot.x, spot.y) * scale + pan;

    return Positioned(
      key: cardKey,
      left: at.dx,
      top: at.dy,
      width: spot.width * scale,
      // Turned and mirrored about its own centre. The box it is positioned in
      // stays square to the canvas, which is what everything else — snapping,
      // the marquee, resizing — goes on reasoning about.
      child: Transform.rotate(
        angle: spot.rotation * math.pi / 180,
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.diagonal3Values(
            spot.flipX ? -1 : 1,
            spot.flipY ? -1 : 1,
            1,
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // From the moment it is touched, not from where the drag was
            // recognised: the default loses the first eighteen pixels of every
            // drag to the slop, which on a canvas reads as the card lagging
            // behind the finger before it catches up.
            dragStartBehavior: DragStartBehavior.down,
            onPanStart: (_) => onGrab(),
            onPanUpdate: (details) => onMove(details.delta),
            onPanEnd: (_) => onRelease(),
            onTap: onGrab,
            // A hold is free on a card — moving one is a drag — so it opens the
            // menu, which is how a phone reaches what a right-click reaches.
            onSecondaryTapUp: (details) {
              onGrab();
              onMenu(details.globalPosition);
            },
            onLongPressStart: (details) {
              onGrab();
              onMenu(details.globalPosition);
            },
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: card.isImage
                        ? Colors.transparent
                        : theme.colorScheme.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: selected
                          ? theme.colorScheme.primary
                          : card.isImage
                          ? Colors.transparent
                          : theme.colorScheme.outlineVariant,
                      width: selected ? 2 : 1,
                    ),
                    boxShadow: selected
                        ? [
                            BoxShadow(
                              color: theme.colorScheme.primary.withValues(
                                alpha: 0.25,
                              ),
                              blurRadius: 12,
                            ),
                          ]
                        : null,
                  ),
                  clipBehavior: Clip.antiAlias,
                  // The content takes no pointers of its own. Rendered markdown
                  // carries gesture recognizers for its links and its text, and
                  // those were winning the arena against the card — so a card
                  // could be looked at and never moved. On a canvas a card is an
                  // object you pick up, not a page you interact with.
                  child: IgnorePointer(
                    child: card.isImage
                        ? _CanvasImage(reference: card.imagePath!)
                        : Padding(
                            padding: EdgeInsets.all(8 * scale.clamp(0.5, 1.5)),
                            child: NoteView(markdown: card.markdown),
                          ),
                  ),
                ),
                if (selected)
                  Positioned(
                    right: -6,
                    bottom: -6,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      dragStartBehavior: DragStartBehavior.down,
                      onPanStart: (_) => onGrab(),
                      onPanUpdate: (details) => onResize(details.delta),
                      onPanEnd: (_) => onRelease(),
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: theme.colorScheme.onPrimary,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ),
                // Turning it: a handle above the card, the way every tool that
                // rotates puts one. Held with shift it steps in fifteens.
                if (selected && !spot.locked)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: -28,
                    child: Center(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        dragStartBehavior: DragStartBehavior.down,
                        onPanStart: (_) => onGrab(),
                        onPanUpdate: (details) =>
                            onRotate(details.globalPosition),
                        onPanEnd: (_) => onRelease(),
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.tertiary,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: theme.colorScheme.onPrimary,
                              width: 2,
                            ),
                          ),
                          child: Icon(
                            Icons.rotate_right,
                            size: 10,
                            color: theme.colorScheme.onTertiary,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A picture on the canvas, at whatever width the card is.
class _CanvasImage extends StatefulWidget {
  const _CanvasImage({required this.reference});

  final String reference;

  @override
  State<_CanvasImage> createState() => _CanvasImageState();
}

class _CanvasImageState extends State<_CanvasImage> {
  late final Future<File?> _file = _load();

  Future<File?> _load() async {
    final repoPath = AttachmentStore.resolveRepoPath(widget.reference);
    if (repoPath == null) return null;
    final state = context.read<AppState>();
    return AttachmentStore().resolve(repoPath, state.config);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return FutureBuilder<File?>(
      future: _file,
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file == null) {
          return AspectRatio(
            aspectRatio: 4 / 3,
            child: Container(
              color: theme.colorScheme.surfaceContainerHighest,
              child: Center(
                child: snapshot.connectionState == ConnectionState.waiting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        Icons.image_not_supported_outlined,
                        color: theme.colorScheme.outline,
                      ),
              ),
            ),
          );
        }
        return Image.file(file, fit: BoxFit.contain);
      },
    );
  }
}

/// Zoom, fit and back to actual size.
class _CanvasControls extends StatelessWidget {
  const _CanvasControls({
    required this.scale,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFit,
    required this.onReset,
    this.onOpenFullScreen,
  });

  final double scale;
  final VoidCallback? onOpenFullScreen;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onFit;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.95),
      borderRadius: BorderRadius.circular(20),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Zoom out',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.remove, size: 18),
              onPressed: onZoomOut,
            ),
            TextButton(
              onPressed: onReset,
              child: Text(
                '${(scale * 100).round()}%',
                style: theme.textTheme.labelMedium,
              ),
            ),
            IconButton(
              tooltip: 'Zoom in',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add, size: 18),
              onPressed: onZoomIn,
            ),
            IconButton(
              tooltip: TouchInput.isPrimary ? 'Fit all' : 'Fit all (F)',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.fit_screen_outlined, size: 18),
              onPressed: onFit,
            ),
            if (onOpenFullScreen != null)
              IconButton(
                tooltip: 'Open full screen',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.open_in_full, size: 18),
                onPressed: onOpenFullScreen,
              ),
          ],
        ),
      ),
    );
  }
}

/// A faint grid, so panning an empty canvas shows that it is moving.
class _GridPainter extends CustomPainter {
  _GridPainter({required this.pan, required this.scale, required this.colour});

  final Offset pan;
  final double scale;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    const spacing = 80.0;
    final step = spacing * scale;
    if (step < 8) return;

    final paint = Paint()
      ..color = colour
      ..strokeWidth = 1;

    for (var x = pan.dx % step; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = pan.dy % step; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.pan != pan || old.scale != scale || old.colour != colour;
}
