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
    this.onOpenFullScreen,
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

  /// Opens the canvas on a screen of its own. Null when it already is one.
  final VoidCallback? onOpenFullScreen;

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
    if (_active == null && widget.spots != oldWidget.spots) {
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

  /// Moves [index], and everything selected with it — dragging one of a group
  /// takes the group, which is the point of picking several.
  void _moveBy(int index, Offset delta) {
    final moving = _selection.contains(index) ? _selection : {index};
    setState(() {
      for (final at in moving) {
        final spot = _spots[at];
        _spots[at] = spot.copyWith(
          x: spot.x + delta.dx / _scale,
          y: spot.y + delta.dy / _scale,
        );
      }
    });
  }

  void _resizeBy(int index, Offset delta) {
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
    _selection.removeWhere((index) => index >= widget.cards.length);

    // Drawn back to front, so the stacking order is what the z says.
    final order = [for (var i = 0; i < widget.cards.length; i++) i]
      ..sort((a, b) => _spots[a].z.compareTo(_spots[b].z));

    return Focus(
      focusNode: _focus,
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
                    // Raise whatever is now selected, so a group picked up
                    // comes forward together rather than one of it.
                    _bringToFront(
                      _selection.contains(index) ? _selection : {index},
                    );
                  },
                  onMenu: (at) => _showCardMenu(index, at),
                  onMove: (delta) => _moveBy(index, delta),
                  onResize: (delta) => _resizeBy(index, delta),
                  onRelease: () {
                    _active = null;
                    _commit();
                  },
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

  void _showCardMenu(int index, Offset at) {
    // Whatever is selected, or the card that was clicked if it is not part of
    // the selection.
    final targets = _selection.contains(index) ? {..._selection} : {index};
    final many = targets.length > 1;

    showItemMenu(context, [
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
          ],
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
