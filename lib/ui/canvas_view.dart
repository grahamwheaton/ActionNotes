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
import 'image_viewer.dart';
import 'canvas_marks.dart';
import 'canvas_snap.dart';
import 'context_menu.dart';
import 'note_view.dart';
import 'theme.dart';
import 'text_prompt.dart';
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
    this.settings = CanvasSettings.standard,
    this.onSettingsChanged,
    this.onRemoveCard,
    this.onDuplicateCard,
    this.onEditCard,
    this.onPlaceCard,
    this.shapes = const [],
    this.onDrawShape,
    this.onEraseShapes,
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

  /// How this canvas is drawn — its background and whether it keeps its own
  /// light or dark.
  final CanvasSettings settings;

  /// Null where the drawing is not the viewer's to change.
  final ValueChanged<CanvasSettings>? onSettingsChanged;

  /// Takes a card off the canvas, which means off the section's markdown —
  /// null where that is not on offer.
  final void Function(int index)? onRemoveCard;

  /// Puts a copy of a card on the canvas, next to the original.
  final void Function(int index)? onDuplicateCard;

  /// Rewrites a card's markdown — renaming a frame, or retyping a note.
  final void Function(int index, String markdown)? onEditCard;

  /// Puts a new card down at a given spot: what the side tools do. Null where
  /// the canvas is not the viewer's to add to.
  final void Function(String markdown, CanvasSpot spot)? onPlaceCard;

  /// What has been drawn on the board, oldest first.
  final List<CanvasShape> shapes;

  /// A new mark, once it has been drawn.
  final ValueChanged<CanvasShape>? onDrawShape;

  /// Marks to rub out, by their index in [shapes].
  final ValueChanged<Set<int>>? onEraseShapes;

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
  /// What the next press on empty canvas will do.
  ///
  /// Select is the canvas as it was, and every other tool goes back to it the
  /// moment it has placed one thing: a tool that stays armed puts a second
  /// sticky note down the next time you meant to click something.
  CanvasTool _tool = CanvasTool.select;
  CanvasColour _colour = CanvasColour.yellow;

  /// The mark being drawn, in scene coordinates, before it is committed.
  List<double>? _drawing;

  /// What the eraser has passed over during this stroke.
  final Set<int> _rubbed = {};

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

  void _drawStart(Offset viewportPoint) {
    final scene = _toScene(viewportPoint);
    setState(() => _drawing = [scene.dx, scene.dy, scene.dx, scene.dy]);
  }

  void _drawUpdate(Offset viewportPoint) {
    final drawing = _drawing;
    if (drawing == null) return;
    final scene = _toScene(viewportPoint);

    setState(() {
      if (_tool == CanvasTool.pen) {
        // Every wobble of a freehand line would be a hundred numbers in the
        // file, so a point is kept only once the pen has actually gone
        // somewhere.
        final lastX = drawing[drawing.length - 2];
        final lastY = drawing[drawing.length - 1];
        if ((scene.dx - lastX).abs() + (scene.dy - lastY).abs() < 3 / _scale) {
          return;
        }
        drawing.addAll([scene.dx, scene.dy]);
        return;
      }
      // Everything else is two points: where it started and where it is now.
      drawing[2] = scene.dx;
      drawing[3] = scene.dy;
    });
  }

  void _drawEnd() {
    final drawing = _drawing;
    final kind = _tool.draws;
    setState(() {
      _drawing = null;
      // The pen keeps going, because a drawing is many strokes; a single
      // shape is one thing, so its tool disarms like the rest.
      if (_tool != CanvasTool.pen) _tool = CanvasTool.select;
    });
    if (drawing == null || kind == null) return;

    // A press that went nowhere is a press, not a mark.
    final from = Offset(drawing[0], drawing[1]);
    final to = Offset(drawing[drawing.length - 2], drawing[drawing.length - 1]);
    if (drawing.length == 4 && (to - from).distance < 4) return;

    widget.onDrawShape?.call(
      CanvasShape(
        kind: kind,
        points: List.unmodifiable(drawing),
        colour: _colour,
      ),
    );
  }

  /// Rubs out whatever the eraser is dragged over.
  void _rub(Offset viewportPoint) {
    final scene = _toScene(viewportPoint);
    final reach = 10 / _scale;
    for (var i = 0; i < widget.shapes.length; i++) {
      if (_rubbed.contains(i)) continue;
      if (CanvasMarks.touches(widget.shapes[i], scene, reach)) _rubbed.add(i);
    }
  }

  void _rubEnd() {
    if (_rubbed.isEmpty) return;
    widget.onEraseShapes?.call({..._rubbed});
    _rubbed.clear();
  }

  /// A tool's press on empty canvas: put the thing down where it landed.
  Future<void> _useTool(Offset viewportPoint) async {
    final tool = _tool;
    if (tool == CanvasTool.select || widget.onPlaceCard == null) return;

    final scene = _toScene(viewportPoint);
    final text = await TextPromptDialog.show(
      context,
      title: switch (tool) {
        CanvasTool.sticky => 'What does the note say?',
        CanvasTool.text => 'What does it say?',
        _ => 'Name the frame',
      },
      initialValue: tool == CanvasTool.frame ? 'Frame' : '',
      confirmLabel: 'Add',
      maxLines: tool == CanvasTool.frame ? 1 : 5,
      minLines: tool == CanvasTool.frame ? null : 2,
    );
    if (!mounted) return;
    setState(() => _tool = CanvasTool.select);
    if (text == null || text.trim().isEmpty) return;

    widget.onPlaceCard!(
      text.trim(),
      CanvasSpot(
        // Dropped with its top-left where the press was, which is where a
        // thing you are placing looks like it is going.
        x: scene.dx,
        y: scene.dy,
        width: tool == CanvasTool.frame ? 480 : 220,
        height: tool == CanvasTool.frame ? 360 : null,
        kind: switch (tool) {
          CanvasTool.sticky => CanvasSpotKind.sticky,
          CanvasTool.text => CanvasSpotKind.text,
          CanvasTool.frame => CanvasSpotKind.frame,
          _ => CanvasSpotKind.card,
        },
        colour: tool == CanvasTool.sticky ? _colour : CanvasColour.none,
      ),
    );
  }

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
    final spot = _spots[index];
    // A frame is a rectangle someone drew, so it knows its own height rather
    // than taking it from what is inside it.
    if (spot.height != null) return Size(spot.width, spot.height!);

    final render = _cardKeys[index]?.currentContext?.findRenderObject();
    final width = spot.width;
    if (render is! RenderBox || !render.hasSize) return Size(width, width);
    return Size(width, render.size.height / _scale);
  }

  /// What a frame is holding: everything whose middle stands on it.
  ///
  /// By the middle rather than by overlap, so a card poking over the edge
  /// still belongs to the frame it is mostly on and a card merely brushing
  /// one does not get carried off by it.
  Set<int> _within(int frame) {
    final bounds = _sceneRect(frame);
    return {
      for (var i = 0; i < _spots.length; i++)
        if (i != frame &&
            !_spots[i].isFrame &&
            bounds.contains(_sceneRect(i).center))
          i,
    };
  }

  Rect _sceneRect(int index) {
    final spot = _spots[index];
    return Offset(spot.x, spot.y) & _sceneSize(index);
  }

  void _beginDrag(int index) {
    var moving = _selection.contains(index) ? {..._selection} : {index};
    // Picking up a frame picks up what is standing on it, which is what a
    // frame is for. Worked out as the drag starts, so a card does not join or
    // leave the group halfway across the canvas.
    for (final at in moving.toList()) {
      if (_spots[at].isFrame) moving = {...moving, ..._within(at)};
    }
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
        // A card's height follows what is in it, so only its width is
        // dragged. A frame is a rectangle, so both corners move.
        height: spot.height == null
            ? null
            : math.max(80, spot.height! + delta.dy / _scale),
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
        // Plain Z zooms to what is selected; with a modifier it is undo, and
        // that belongs to the screen above rather than here.
        if (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed) {
          return KeyEventResult.ignored;
        }
        zoomToSelection();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        if (_selection.isEmpty) return KeyEventResult.ignored;
        setState(_selection.clear);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyI:
        if (!HardwareKeyboard.instance.isControlPressed &&
            !HardwareKeyboard.instance.isMetaPressed) {
          return KeyEventResult.ignored;
        }
        setState(() {
          final inverted = <int>{
            for (var i = 0; i < widget.cards.length; i++)
              if (!_selection.contains(i)) i,
          };
          _selection
            ..clear()
            ..addAll(inverted);
        });
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
    final settings = widget.settings;
    // A canvas can keep its own light or dark: a moodboard of photographs
    // usually wants the dark one whatever the rest of the app is set to, and
    // a board of notes usually wants the light one. Null follows the app,
    // which is what a canvas did before this was on offer.
    final theme = settings.dark == null
        ? Theme.of(context)
        : (settings.dark! ? AppTheme.dark() : AppTheme.light());
    final touch = TouchInput.isPrimary;
    // Whether the drag on empty canvas is drawing rather than selecting,
    // panning or zooming.
    final drawing =
        widget.onDrawShape != null &&
        (_tool.draws != null || _tool == CanvasTool.eraser);

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

    return Theme(
      data: theme,
      child: Focus(
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
                // The canvas's own paper. Only when it is keeping a light or
                // dark of its own — otherwise whatever it is sitting in shows
                // through, the way it always did.
                if (settings.dark != null)
                  Positioned.fill(
                    child: ColoredBox(color: theme.colorScheme.surface),
                  ),
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) {
                      _focus.requestFocus();
                      // A tool that is armed puts its thing down where the
                      // press landed; select clears the selection, which is
                      // what a press on empty canvas always did.
                      if (_tool.places) {
                        _useTool(details.localPosition);
                        return;
                      }
                      // A drawing tool is worked by dragging; a press with
                      // one armed is not a mark, so it does nothing rather
                      // than quietly clearing the selection behind it.
                      if (_tool != CanvasTool.select) return;
                      setState(_selection.clear);
                    },
                    // Under a finger, a drag pans and two fingers zoom. With a
                    // mouse, a drag draws a marquee unless space is held, and
                    // panning is the middle button, space and drag, or the
                    // wheel.
                    //
                    // A drawing tool takes the drag on either, finger or
                    // mouse, since drawing is what the drag is now for. Two
                    // fingers stop zooming while one is armed, which is the
                    // price of being able to draw with one.
                    onScaleStart: touch && !drawing ? _onScaleStart : null,
                    onScaleUpdate: touch && !drawing ? _onScaleUpdate : null,
                    onPanStart: drawing
                        ? (details) {
                            _focus.requestFocus();
                            if (_tool == CanvasTool.eraser) {
                              _rub(details.localPosition);
                              return;
                            }
                            _drawStart(details.localPosition);
                          }
                        : touch
                        ? null
                        : (details) {
                            _focus.requestFocus();
                            // Space held: this drag pans instead of selecting,
                            // and leaving the marquee unstarted is what the
                            // update below reads as "pan".
                            if (_panning) return;
                            _marqueeStart(details.localPosition);
                          },
                    onPanUpdate: drawing
                        ? (details) {
                            if (_tool == CanvasTool.eraser) {
                              setState(() => _rub(details.localPosition));
                              return;
                            }
                            _drawUpdate(details.localPosition);
                          }
                        : touch
                        ? null
                        : (details) {
                            if (_marqueeFrom != null) {
                              _marqueeUpdate(details.localPosition);
                              return;
                            }
                            setState(() => _pan += details.delta);
                          },
                    onPanEnd: drawing
                        ? (_) {
                            if (_tool == CanvasTool.eraser) {
                              setState(_rubEnd);
                              return;
                            }
                            _drawEnd();
                          }
                        : touch
                        ? null
                        : (_) => _marqueeEnd(),
                    child: CustomPaint(
                      painter: _GridPainter(
                        pan: _pan,
                        scale: _scale,
                        style: settings.background,
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
                // Over the cards: an arrow pointing at a reference has to be
                // on top of it to mean anything. It takes no pointers, so a
                // card under a stroke is still a card you can pick up.
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _MarksPainter(
                        shapes: widget.shapes,
                        pending: _drawing,
                        pendingKind: _tool.draws,
                        pendingColour: _colour,
                        pan: _pan,
                        scale: _scale,
                        theme: theme,
                        rubbed: _rubbed,
                      ),
                    ),
                  ),
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
                    bottom: 8 + MediaQuery.viewPaddingOf(context).bottom,
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
                if (widget.onPlaceCard != null)
                  Positioned(
                    left: 8,
                    top: 0,
                    bottom: 0,
                    // Down the middle of the left edge, the way every tool
                    // that has a tool column puts one — and clear of the top
                    // left corner, which is where a canvas starts and so
                    // where its first cards sit.
                    child: Center(
                      child: _CanvasTools(
                        tool: _tool,
                        colour: _colour,
                        onTool: (tool) => setState(
                          () =>
                              _tool = _tool == tool ? CanvasTool.select : tool,
                        ),
                        onColour: (colour) => setState(() => _colour = colour),
                      ),
                    ),
                  ),
                Positioned(
                  right: 8,
                  // Clear of the system bar at the bottom of a phone, which was
                  // sitting on top of the zoom controls.
                  bottom: 8 + MediaQuery.viewPaddingOf(context).bottom,
                  child: _CanvasControls(
                    scale: _scale,
                    settings: settings,
                    onSettingsChanged: widget.onSettingsChanged,
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

  /// Scales everything selected so that one measurement of it matches.
  ///
  /// Height, width or area, taken either from the first card of the selection
  /// or averaged across it — which is the pair of choices PureRef offers, and
  /// they are genuinely different jobs: "make these match that one" and "even
  /// these out".
  ///
  /// A card's height follows its width, so every one of these comes out as a
  /// new width. Area is the one that makes a wall of references read evenly,
  /// because a tall photograph and a wide one at the same width are nothing
  /// like the same size on a board; its factor is the square root of the
  /// ratio, since the area goes as the square of the width.
  void _normalise(
    Set<int> targets,
    _Measure measure, {
    required bool fromFirst,
  }) {
    if (targets.length < 2) return;

    // In the order they are on the canvas, so "the first" means something a
    // person can point at rather than whichever was clicked first.
    final order = targets.toList()..sort();

    final values = <int, double>{};
    for (final at in order) {
      final size = _sceneSize(at);
      final value = switch (measure) {
        _Measure.height => size.height,
        _Measure.width => size.width,
        _Measure.area => size.width * size.height,
      };
      if (value > 0) values[at] = value;
    }
    if (values.length < 2) return;

    final target = fromFirst
        ? values[order.firstWhere(values.containsKey)]!
        : values.values.reduce((a, b) => a + b) / values.length;

    setState(() {
      for (final entry in values.entries) {
        final spot = _spots[entry.key];
        if (spot.locked) continue;
        final ratio = target / entry.value;
        final factor = measure == _Measure.area ? math.sqrt(ratio) : ratio;
        _spots[entry.key] = spot.copyWith(
          width: (spot.width * factor).clamp(40.0, 4000.0),
        );
      }
    });
    _commit();
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

  /// What a card is drawn on. A colour makes it a sticky note; Plain puts it
  /// back to an ordinary card, which is what it was before anyone chose.
  void _showColourMenu(Set<int> targets, Offset at) {
    showItemMenu(context, [
      for (final option in CanvasColour.values)
        ContextMenuAction(
          label: option.label,
          icon: option == CanvasColour.none ? Icons.hide_source : Icons.circle,
          onSelected: () => _transform(
            targets,
            (spot) => spot.copyWith(
              colour: option,
              kind: option == CanvasColour.none
                  ? CanvasSpotKind.card
                  : CanvasSpotKind.sticky,
            ),
          ),
        ),
    ], at);
  }

  /// Which measurement is being evened out, and against what.
  void _showNormaliseMenu(Set<int> targets, Offset at) {
    showItemMenu(context, [
      for (final measure in _Measure.values) ...[
        ContextMenuAction(
          label: '${measure.label}: average',
          icon: measure.icon,
          onSelected: () => _normalise(targets, measure, fromFirst: false),
        ),
        ContextMenuAction(
          label: '${measure.label}: match the first',
          icon: measure.icon,
          onSelected: () => _normalise(targets, measure, fromFirst: true),
        ),
      ],
    ], at);
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
      ContextMenuAction(
        label: 'Normalise…',
        icon: Icons.photo_size_select_large,
        onSelected: () => _showNormaliseMenu(targets, at),
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

  /// The file behind an image card, once it has been fetched.
  Future<File?> _fileFor(int index) async {
    final path = widget.cards[index].imagePath;
    if (path == null) return null;
    final repoPath = AttachmentStore.resolveRepoPath(path);
    if (repoPath == null) return null;
    if (!mounted) return null;
    return AttachmentStore().resolve(repoPath, context.read<AppState>().config);
  }

  /// Runs one of the picture actions and says what happened.
  Future<void> _withFile(
    int index,
    Future<String?> Function(File) action,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final file = await _fileFor(index);
    if (file == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('That picture is not here yet.')),
      );
      return;
    }
    final message = await action(file);
    if (message != null) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _editCard(int index) async {
    final frame = _spots[index].isFrame;
    final text = await TextPromptDialog.show(
      context,
      title: frame ? 'Rename the frame' : 'Edit the card',
      initialValue: widget.cards[index].markdown,
      maxLines: frame ? 1 : 6,
      minLines: frame ? null : 2,
    );
    if (text == null) return;
    widget.onEditCard?.call(index, text);
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
        label: 'Invert the selection',
        icon: Icons.flip_camera_android_outlined,
        onSelected: () => setState(() {
          _selection
            ..clear()
            ..addAll([
              for (var i = 0; i < widget.cards.length; i++)
                if (!targets.contains(i)) i,
            ]);
        }),
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
      if (!many && widget.onEditCard != null && !widget.cards[index].isImage)
        ContextMenuAction(
          label: _spots[index].isFrame ? 'Rename frame' : 'Edit text',
          icon: Icons.edit_outlined,
          onSelected: () => _editCard(index),
        ),
      if (!widget.cards[index].isImage && !_spots[index].isFrame)
        ContextMenuAction(
          label: 'Colour…',
          icon: Icons.palette_outlined,
          onSelected: () => _showColourMenu(targets, at),
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
      // A reference on a board is often wanted somewhere else, so the things
      // the rest of the app already does with a picture are here too.
      if (!many && widget.cards[index].isImage) ...[
        ContextMenuAction(
          label: 'Copy image',
          icon: Icons.copy,
          onSelected: () => _withFile(index, ImageActions.copy),
        ),
        ContextMenuAction(
          label: 'Save a copy',
          icon: Icons.save_alt,
          onSelected: () => _withFile(
            index,
            (file) => ImageActions.saveCopy(file, file.uri.pathSegments.last),
          ),
        ),
        if (ImageActions.canReveal)
          ContextMenuAction(
            label: 'Show in folder',
            icon: Icons.folder_open,
            onSelected: () => _withFile(index, ImageActions.reveal),
          ),
      ],
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
/// What "the same size" is being measured by.
enum _Measure {
  area,
  width,
  height;

  String get label => switch (this) {
    _Measure.area => 'Area',
    _Measure.width => 'Width',
    _Measure.height => 'Height',
  };

  IconData get icon => switch (this) {
    _Measure.area => Icons.photo_size_select_large,
    _Measure.width => Icons.width_wide,
    _Measure.height => Icons.height,
  };
}

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
      // A frame is drawn at the size it was given; a card is as tall as what
      // is in it.
      height: spot.height == null ? null : spot.height! * scale,
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
                    color: spot.isFrame
                        // Barely there: a frame is a boundary, not a panel,
                        // and what stands on it has to stay readable.
                        ? theme.colorScheme.surfaceContainerHighest.withValues(
                            alpha: 0.35,
                          )
                        : card.isImage || !spot.hasPaper
                        // Writing straight on the board, and a picture that
                        // is its own shape: neither wants a card behind it.
                        ? Colors.transparent
                        : canvasColourOf(spot.colour, theme),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: selected
                          ? theme.colorScheme.primary
                          : spot.isFrame
                          ? theme.colorScheme.outline
                          : card.isImage || !spot.hasPaper
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
                    child: spot.isFrame
                        // A frame shows only its name, at the top left where
                        // a label goes — the rest of it is the space it
                        // encloses, and drawing anything there would be
                        // drawing over what it is holding.
                        ? Align(
                            alignment: Alignment.topLeft,
                            child: Padding(
                              padding: EdgeInsets.all(
                                6 * scale.clamp(0.5, 1.5),
                              ),
                              child: Text(
                                card.markdown,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelLarge
                                    ?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                      fontWeight: FontWeight.w600,
                                    )
                                    .apply(
                                      fontSizeFactor: scale.clamp(0.6, 1.4),
                                    ),
                              ),
                            ),
                          )
                        : card.isImage
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
    required this.settings,
    required this.onSettingsChanged,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFit,
    required this.onReset,
    this.onOpenFullScreen,
  });

  final double scale;
  final CanvasSettings settings;
  final ValueChanged<CanvasSettings>? onSettingsChanged;
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
            if (onSettingsChanged != null)
              PopupMenuButton<void>(
                tooltip: 'How the canvas looks',
                icon: const Icon(Icons.tune, size: 18),
                iconSize: 18,
                position: PopupMenuPosition.under,
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    enabled: false,
                    height: 32,
                    child: Text('Background'),
                  ),
                  for (final option in CanvasBackground.values)
                    CheckedPopupMenuItem(
                      checked: settings.background == option,
                      onTap: () => onSettingsChanged!(
                        settings.copyWith(background: option),
                      ),
                      child: Text(option.label),
                    ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    enabled: false,
                    height: 32,
                    child: Text('Shade'),
                  ),
                  CheckedPopupMenuItem(
                    checked: settings.dark == null,
                    onTap: () =>
                        onSettingsChanged!(settings.copyWith(clearDark: true)),
                    child: const Text('Match the app'),
                  ),
                  CheckedPopupMenuItem(
                    checked: settings.dark == false,
                    onTap: () =>
                        onSettingsChanged!(settings.copyWith(dark: false)),
                    child: const Text('Light'),
                  ),
                  CheckedPopupMenuItem(
                    checked: settings.dark == true,
                    onTap: () =>
                        onSettingsChanged!(settings.copyWith(dark: true)),
                    child: const Text('Dark'),
                  ),
                ],
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

/// The marks drawn on a canvas, painted over the cards.
///
/// Over rather than under, because an arrow pointing at a reference has to be
/// on top of the thing it points at to mean anything. It takes no pointers,
/// so a card under a stroke is still a card that can be picked up.
class _MarksPainter extends CustomPainter {
  _MarksPainter({
    required this.shapes,
    required this.pending,
    required this.pendingKind,
    required this.pendingColour,
    required this.pan,
    required this.scale,
    required this.theme,
    required this.rubbed,
  });

  final List<CanvasShape> shapes;

  /// The mark being drawn this moment, which is not in [shapes] yet.
  final List<double>? pending;
  final CanvasShapeKind? pendingKind;
  final CanvasColour pendingColour;

  final Offset pan;
  final double scale;
  final ThemeData theme;

  /// What the eraser has passed over, drawn faintly so that letting go is not
  /// a surprise.
  final Set<int> rubbed;

  Offset _at(List<double> points, int index) =>
      Offset(points[index * 2], points[index * 2 + 1]) * scale + pan;

  Color _colourOf(CanvasColour colour) => colour == CanvasColour.none
      ? theme.colorScheme.onSurface
      : canvasColourOf(colour, theme);

  void _draw(
    Canvas canvas,
    CanvasShapeKind kind,
    List<double> points,
    CanvasColour colour,
    double thickness,
    double opacity,
  ) {
    if (points.length < 4) return;

    final paint = Paint()
      ..color = _colourOf(colour).withValues(alpha: opacity)
      ..strokeWidth = math.max(1, thickness * scale)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    switch (kind) {
      case CanvasShapeKind.line:
        canvas.drawLine(_at(points, 0), _at(points, 1), paint);
      case CanvasShapeKind.arrow:
        final from = _at(points, 0);
        final to = _at(points, 1);
        canvas.drawLine(from, to, paint);
        _head(canvas, from, to, paint);
      case CanvasShapeKind.rectangle:
        canvas.drawRect(Rect.fromPoints(_at(points, 0), _at(points, 1)), paint);
      case CanvasShapeKind.oval:
        canvas.drawOval(Rect.fromPoints(_at(points, 0), _at(points, 1)), paint);
      case CanvasShapeKind.stroke:
        final path = Path()..moveTo(_at(points, 0).dx, _at(points, 0).dy);
        for (var i = 1; i < points.length ~/ 2; i++) {
          final point = _at(points, i);
          path.lineTo(point.dx, point.dy);
        }
        canvas.drawPath(path, paint);
    }
  }

  /// A plain two-stroke head, sized with the zoom so an arrow does not grow a
  /// spearhead when the board is zoomed in.
  void _head(Canvas canvas, Offset from, Offset to, Paint paint) {
    final along = to - from;
    if (along.distance < 1) return;

    final angle = math.atan2(along.dy, along.dx);
    final length = math.min(18 * scale, along.distance / 2);
    const spread = 0.5;

    for (final side in [-spread, spread]) {
      canvas.drawLine(
        to,
        to -
            Offset(
              math.cos(angle + side) * length,
              math.sin(angle + side) * length,
            ),
        paint,
      );
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < shapes.length; i++) {
      final shape = shapes[i];
      _draw(
        canvas,
        shape.kind,
        shape.points,
        shape.colour,
        shape.thickness,
        rubbed.contains(i) ? 0.2 : 1,
      );
    }

    final drawing = pending;
    if (drawing != null && pendingKind != null) {
      _draw(canvas, pendingKind!, drawing, pendingColour, 2, 0.7);
    }
  }

  @override
  bool shouldRepaint(_MarksPainter old) => true;
}

/// What the next press on the canvas will do.
enum CanvasTool {
  select,
  sticky,
  text,
  frame,
  line,
  arrow,
  rectangle,
  oval,
  pen,
  eraser;

  String get label => switch (this) {
    CanvasTool.select => 'Select',
    CanvasTool.sticky => 'Sticky note',
    CanvasTool.text => 'Text',
    CanvasTool.frame => 'Frame',
    CanvasTool.line => 'Line',
    CanvasTool.arrow => 'Arrow',
    CanvasTool.rectangle => 'Rectangle',
    CanvasTool.oval => 'Oval',
    CanvasTool.pen => 'Pen',
    CanvasTool.eraser => 'Eraser',
  };

  IconData get icon => switch (this) {
    CanvasTool.select => Icons.near_me_outlined,
    CanvasTool.sticky => Icons.sticky_note_2_outlined,
    CanvasTool.text => Icons.title,
    CanvasTool.frame => Icons.crop_free,
    CanvasTool.line => Icons.horizontal_rule,
    CanvasTool.arrow => Icons.north_east,
    CanvasTool.rectangle => Icons.crop_square,
    CanvasTool.oval => Icons.circle_outlined,
    CanvasTool.pen => Icons.draw_outlined,
    CanvasTool.eraser => Icons.auto_fix_normal,
  };

  /// Placed by pressing once and saying what it says.
  bool get places =>
      this == CanvasTool.sticky ||
      this == CanvasTool.text ||
      this == CanvasTool.frame;

  /// Drawn by dragging, rather than placed by pressing.
  CanvasShapeKind? get draws => switch (this) {
    CanvasTool.line => CanvasShapeKind.line,
    CanvasTool.arrow => CanvasShapeKind.arrow,
    CanvasTool.rectangle => CanvasShapeKind.rectangle,
    CanvasTool.oval => CanvasShapeKind.oval,
    CanvasTool.pen => CanvasShapeKind.stroke,
    _ => null,
  };
}

/// The tools down the side of a canvas.
///
/// A column rather than another row along the bottom: the bottom already has
/// the zoom controls, and a board is usually wider than it is tall, so the
/// side is the edge with room to spare.
///
/// The four shapes share one button. Ten buttons in a column is taller than a
/// phone, and a shape is picked rarely enough that one more press to reach it
/// is a fair trade for the column fitting on the screen at all.
class _CanvasTools extends StatelessWidget {
  const _CanvasTools({
    required this.tool,
    required this.colour,
    required this.onTool,
    required this.onColour,
  });

  final CanvasTool tool;
  final CanvasColour colour;
  final ValueChanged<CanvasTool> onTool;
  final ValueChanged<CanvasColour> onColour;

  static const _shapes = [
    CanvasTool.line,
    CanvasTool.arrow,
    CanvasTool.rectangle,
    CanvasTool.oval,
  ];

  static const _own = [
    CanvasTool.select,
    CanvasTool.sticky,
    CanvasTool.text,
    CanvasTool.frame,
  ];

  /// Whether what is armed is coloured by the swatches: a note is drawn on a
  /// colour, and a mark is drawn in one.
  bool get _colouring => tool == CanvasTool.sticky || tool.draws != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shape = _shapes.contains(tool) ? tool : CanvasTool.arrow;

    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.95),
      borderRadius: BorderRadius.circular(20),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in _own)
              IconButton(
                tooltip: option.label,
                visualDensity: VisualDensity.compact,
                isSelected: tool == option,
                selectedIcon: Icon(
                  option.icon,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                icon: Icon(option.icon, size: 18),
                onPressed: () => onTool(option),
              ),
            // The button both arms the shape last used and, held or
            // right-clicked, offers the others — so the common case is one
            // press and the rest is one more.
            PopupMenuButton<CanvasTool>(
              tooltip: 'Shapes',
              position: PopupMenuPosition.under,
              iconSize: 18,
              icon: Icon(
                shape.icon,
                size: 18,
                color: _shapes.contains(tool)
                    ? theme.colorScheme.primary
                    : null,
              ),
              onSelected: onTool,
              itemBuilder: (_) => [
                for (final option in _shapes)
                  PopupMenuItem(
                    value: option,
                    child: Row(
                      children: [
                        Icon(option.icon, size: 18),
                        const SizedBox(width: 10),
                        Text(option.label),
                      ],
                    ),
                  ),
              ],
            ),
            for (final option in [CanvasTool.pen, CanvasTool.eraser])
              IconButton(
                tooltip: option.label,
                visualDensity: VisualDensity.compact,
                isSelected: tool == option,
                selectedIcon: Icon(
                  option.icon,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                icon: Icon(option.icon, size: 18),
                onPressed: () => onTool(option),
              ),
            // Only while something is armed that a colour would apply to: a
            // row of swatches with nothing to colour is a row of buttons that
            // do nothing.
            if (_colouring) ...[
              const Divider(height: 8, indent: 6, endIndent: 6),
              for (final option in CanvasColour.values)
                // Plain means "no colour", which for a note is the card it
                // always was and for a mark is ordinary ink. Nothing to offer
                // for a note, since that is just not making it a note.
                if (option != CanvasColour.none || tool.draws != null)
                  Tooltip(
                    message: option == CanvasColour.none ? 'Ink' : option.label,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => onColour(option),
                      child: Padding(
                        padding: const EdgeInsets.all(5),
                        child: Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            color: option == CanvasColour.none
                                ? theme.colorScheme.onSurface
                                : canvasColourOf(option, theme),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: option == colour
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.outlineVariant,
                              width: option == colour ? 2 : 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
            ],
          ],
        ),
      ),
    );
  }
}

/// What a named colour actually looks like on the shade in use.
///
/// Mixed into the surface in the dark rather than used neat, so a board of
/// notes reads as paper in the light and as tinted card in the dark, instead
/// of six shouting squares on either.
Color canvasColourOf(CanvasColour colour, ThemeData theme) {
  final base = switch (colour) {
    CanvasColour.none => theme.colorScheme.surfaceContainerLowest,
    CanvasColour.yellow => const Color(0xFFFFE082),
    CanvasColour.pink => const Color(0xFFF8BBD0),
    CanvasColour.blue => const Color(0xFFB3E5FC),
    CanvasColour.green => const Color(0xFFC5E1A5),
    CanvasColour.orange => const Color(0xFFFFCC80),
    CanvasColour.purple => const Color(0xFFD1C4E9),
  };
  if (colour == CanvasColour.none) return base;
  return theme.brightness == Brightness.dark
      ? Color.alphaBlend(
          base.withValues(alpha: 0.35),
          theme.colorScheme.surface,
        )
      : base;
}

/// What is under the cards, so panning an empty canvas shows that it is
/// moving — and so a board can be read against dots, against a grid, or
/// against nothing at all.
class _GridPainter extends CustomPainter {
  _GridPainter({
    required this.pan,
    required this.scale,
    required this.colour,
    required this.style,
  });

  final Offset pan;
  final double scale;
  final Color colour;
  final CanvasBackground style;

  @override
  void paint(Canvas canvas, Size size) {
    if (style == CanvasBackground.plain) return;

    const spacing = 80.0;
    final step = spacing * scale;
    // Zoomed far enough out the marks merge into a wash, which reads as a
    // tinted canvas rather than as a background. Better to have none.
    if (step < 8) return;

    final paint = Paint()
      ..color = colour
      ..strokeWidth = 1;

    if (style == CanvasBackground.dots) {
      // A dot at every crossing, sized so it stays a mark rather than
      // becoming a blob as the canvas is zoomed in.
      final radius = math.min(1.6, 0.9 * math.max(scale, 0.6));
      for (var x = pan.dx % step; x < size.width; x += step) {
        for (var y = pan.dy % step; y < size.height; y += step) {
          canvas.drawCircle(Offset(x, y), radius, paint);
        }
      }
      return;
    }

    for (var x = pan.dx % step; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = pan.dy % step; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.pan != pan ||
      old.scale != scale ||
      old.colour != colour ||
      old.style != style;
}
