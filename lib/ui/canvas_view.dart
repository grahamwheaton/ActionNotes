import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../markdown/canvas_cards.dart';
import '../models/canvas_layout.dart';
import '../state/app_state.dart';
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
    this.onAddImage,
    this.shapes = const [],
    this.onDrawShape,
    this.onEraseShapes,
    this.onEditShape,
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

  /// Import an image at this scene point (or the visible centre).
  final void Function(Offset? scene)? onAddImage;

  /// What has been drawn on the board, oldest first.
  final List<CanvasShape> shapes;

  /// A new mark, once it has been drawn.
  final ValueChanged<CanvasShape>? onDrawShape;

  /// Marks to rub out, by their index in [shapes].
  final ValueChanged<Set<int>>? onEraseShapes;

  /// One mark, changed — a node added, moved or taken out, or a line bent.
  final void Function(int index, CanvasShape shape)? onEditShape;

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
  CanvasTool _lastLineTool = CanvasTool.arrow;
  CanvasColour _colour = CanvasColour.yellow;

  /// How heavy a mark the pen and the shapes make.
  double _thickness = 2;

  /// Smooth future pen strokes without changing marks already on the board.
  bool _smoothPen = false;

  /// The mark being drawn, in scene coordinates, before it is committed.
  List<double>? _drawing;

  /// The mark whose nodes are on show, by its index in the drawing.
  ///
  /// Picked by right-clicking it, and let go by pressing empty canvas or
  /// Escape. Marks are not part of the card selection: they are drawn on the
  /// board rather than standing on it, so lining them up, stacking them and
  /// moving them in a group would all mean something else.
  int? _picked;

  /// Where the pointer is on the canvas, while a tool that snaps is armed.
  /// Only used to show what an arrow would hold on to, so it is not tracked
  /// at any other time.
  Offset? _pointer;

  /// What the eraser has passed over during this stroke.
  final Set<int> _rubbed = {};

  /// Marks riding along with a frame that is being dragged, and where they
  /// started. Drawn shifted while the drag runs and written once at the end:
  /// a stroke is a hundred numbers, and rewriting the file on every frame of
  /// a drag would be a hundred numbers a frame.
  final Map<int, List<double>> _marksRiding = {};
  Offset _marksShift = Offset.zero;

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

  Offset sceneAtViewportCentre() => _toScene(_centre());

  void _chooseTool(CanvasTool tool) {
    setState(() {
      if (tool == CanvasTool.line || tool == CanvasTool.arrow ||
          tool == CanvasTool.bendyArrow) {
        _lastLineTool = tool;
      }
      _tool = _tool == tool ? CanvasTool.select : tool;
    });
  }

  Future<void> _showEmptyMenu(Offset scene, Offset global) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selected = await showMenu<Object>(
      context: context,
      position: RelativeRect.fromLTRB(global.dx, global.dy,
          overlay.size.width - global.dx, overlay.size.height - global.dy),
      items: [
        if (widget.onAddImage != null)
          const PopupMenuItem(value: 'image', child: Text('Image')),
        for (final tool in [CanvasTool.sticky, CanvasTool.text,
          CanvasTool.frame, CanvasTool.rectangle, CanvasTool.oval,
          CanvasTool.line, CanvasTool.arrow, CanvasTool.bendyArrow])
          PopupMenuItem(value: tool, child: Text(tool.label)),
      ],
    );
    if (!mounted || selected == null) return;
    if (selected == 'image') {
      widget.onAddImage?.call(scene);
      return;
    }
    if (selected is! CanvasTool) return;
    _chooseTool(selected);
    if (selected.places) {
      _useTool(scene * _scale + _pan);
    }
  }

  void _drawStart(Offset viewportPoint) {
    final scene = _toScene(viewportPoint);
    setState(() {
      _pointer = viewportPoint;
      _drawing = [scene.dx, scene.dy, scene.dx, scene.dy];
    });
  }

  /// The place an arrow would take hold if it were let go here, or null when
  /// there is nothing near enough to hold on to.
  ///
  /// Shown while the arrow tool is armed so that snapping is something you
  /// watch happen rather than something you find out about afterwards.
  ({Rect card, Offset at})? _holdNear(Offset scene) {
    for (final entry in _holdTargets.entries) {
      if (!entry.value.inflate(8 / _scale).contains(scene)) continue;
      final hold = CanvasMarks.nearestHold(entry.value, scene);
      return (
        card: entry.value,
        at: Offset(
          entry.value.left + entry.value.width * hold.dx,
          entry.value.top + entry.value.height * hold.dy,
        ),
      );
    }
    return null;
  }

  void _drawUpdate(Offset viewportPoint) {
    final drawing = _drawing;
    if (drawing == null) return;
    final scene = _toScene(viewportPoint);

    setState(() {
      _pointer = viewportPoint;
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

  Future<void> _drawEnd() async {
    final drawing = _drawing;
    final tool = _tool;
    final kind = tool.draws;
    setState(() {
      _drawing = null;
      _pointer = null;
      // The pen keeps going, because a drawing is many strokes; a single
      // shape is one thing, so its tool disarms like the rest.
      if (tool != CanvasTool.pen) _tool = CanvasTool.select;
    });
    if (drawing == null) return;

    // A press that went nowhere is a press, not a mark.
    final from = Offset(drawing[0], drawing[1]);
    final to = Offset(drawing[drawing.length - 2], drawing[drawing.length - 1]);
    if (drawing.length == 4 && (to - from).distance < 4) return;

    if (tool == CanvasTool.frame) {
      await _placeFrame(Rect.fromPoints(from, to));
      return;
    }
    if (kind == null) return;

    // An arrow that ends on a card holds on to it, so moving the card takes
    // the arrow with it. Only arrows: a box drawn round three references is
    // a box round that spot on the board, not a thing attached to one of
    // them.
    CanvasAnchor? hold(Offset point) {
      if (kind != CanvasShapeKind.arrow) return null;
      for (final entry in _holdTargets.entries) {
        if (!entry.value.inflate(8 / _scale).contains(point)) continue;
        final at = CanvasMarks.nearestHold(entry.value, point);
        return CanvasAnchor(ref: entry.key, ax: at.dx, ay: at.dy);
      }
      return null;
    }

    widget.onDrawShape?.call(
      CanvasShape(
        kind: kind,
        points: List.unmodifiable(drawing),
        colour: _colour,
        thickness: _thickness,
        curved: tool == CanvasTool.bendyArrow ||
            (tool == CanvasTool.pen && _smoothPen && drawing.length >= 6),
        from: hold(from),
        to: hold(to),
      ),
    );
  }

  /// Names the box that was just dragged out, and puts a frame there.
  Future<void> _placeFrame(Rect box) async {
    final title = await TextPromptDialog.show(
      context,
      title: 'Name the frame',
      initialValue: 'Frame',
      confirmLabel: 'Add',
    );
    if (title == null || !mounted) return;

    widget.onPlaceCard?.call(
      title.trim().isEmpty ? 'Frame' : title.trim(),
      CanvasSpot(
        x: box.left,
        y: box.top,
        // A frame has to be big enough to hold something, so a box dragged
        // out in a flick is nudged up rather than made as a sliver.
        width: math.max(80, box.width),
        height: math.max(80, box.height),
        kind: CanvasSpotKind.frame,
      ),
    );
  }

  /// The topmost mark near [scene], or null — newest first, so the one drawn
  /// last is the one you reach, which is what is on top.
  int? _markNear(Offset scene) {
    final reach = 12 / _scale;
    for (var i = widget.shapes.length - 1; i >= 0; i--) {
      if (CanvasMarks.touches(
        widget.shapes[i],
        scene,
        reach,
        cards: _cardRects,
      )) {
        return i;
      }
    }
    return null;
  }

  /// What can be done to one mark.
  void _showMarkMenu(int index, Offset scene, Offset at) {
    final shape = widget.shapes[index];
    final bendable =
        shape.kind == CanvasShapeKind.arrow ||
        shape.kind == CanvasShapeKind.line;

    setState(() => _picked = index);

    showItemMenu(context, [
      if (bendable)
        ContextMenuAction(
          label: 'Add a node here',
          icon: Icons.add_circle_outline,
          onSelected: () => widget.onEditShape?.call(
            index,
            shape.copyWith(
              points: CanvasMarks.withNodeAt(
                CanvasMarks.pointsOf(shape, _cardRects),
                scene,
              ),
            ),
          ),
        ),
      if (bendable)
        ContextMenuAction(
          label: shape.curved ? 'Make it straight' : 'Make it bendy',
          icon: shape.curved ? Icons.show_chart : Icons.gesture,
          onSelected: () => widget.onEditShape?.call(
            index,
            shape.copyWith(curved: !shape.curved),
          ),
        ),
      ContextMenuAction(
        label: 'Rub it out',
        icon: Icons.auto_fix_normal,
        onSelected: () {
          setState(() => _picked = null);
          widget.onEraseShapes?.call({index});
        },
      ),
    ], at);
  }

  /// Drags one node of the picked mark.
  void _moveNode(int index, int node, Offset delta) {
    final shape = widget.shapes[index];
    final points = CanvasMarks.pointsOf(shape, _cardRects);
    final was = Offset(points[node * 2], points[node * 2 + 1]);

    widget.onEditShape?.call(
      index,
      shape.copyWith(
        points: CanvasMarks.withNodeAtIndex(points, node, was + delta / _scale),
        // A node dragged by hand is where it was put, so an end that was
        // holding on to a card lets go rather than snapping back to it.
        clearFrom: node == 0,
        clearTo: node == points.length ~/ 2 - 1,
      ),
    );
  }

  /// Rubs out whatever the eraser is dragged over.
  void _rub(Offset viewportPoint) {
    final scene = _toScene(viewportPoint);
    final reach = 10 / _scale;
    for (var i = 0; i < widget.shapes.length; i++) {
      if (_rubbed.contains(i)) continue;
      if (CanvasMarks.touches(
        widget.shapes[i],
        scene,
        reach,
        cards: _cardRects,
      )) {
        _rubbed.add(i);
      }
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
      title: tool == CanvasTool.sticky
          ? 'What does the note say?'
          : 'What does it say?',
      confirmLabel: 'Add',
      maxLines: 5,
      minLines: 2,
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
        width: 220,
        kind: tool == CanvasTool.sticky
            ? CanvasSpotKind.sticky
            : CanvasSpotKind.text,
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

  /// Where the finger dragging a card was last seen, so movement is measured
  /// from the moment it touched down rather than from the recogniser's first
  /// update.
  Offset? _dragFocal;

  /// A pinch that began on a card, handed up in global coordinates.
  ///
  /// The board zooms about the point between the fingers, exactly as it does
  /// when the pinch begins on empty space — which is what anybody pinching
  /// over a picture meant.
  void _pinchStart(Offset globalFocal) {
    final local = _toLocal(globalFocal);
    if (local == null) return;
    _panAtStart = _pan;
    _scaleAtStart = _scale;
    _focalAtStart = local;
  }

  void _pinchUpdate(Offset globalFocal, double scale) {
    final local = _toLocal(globalFocal);
    if (local == null) return;
    _applyZoom(local, scale);
  }

  /// Where a point on the screen falls inside the viewport.
  Offset? _toLocal(Offset global) {
    final box = _viewport.currentContext?.findRenderObject() as RenderBox?;
    return box?.globalToLocal(global);
  }

  /// The zoom both pinches share: the point under the fingers when the
  /// gesture started stays under them.
  void _applyZoom(Offset focal, double scale) {
    final next = (_scaleAtStart * scale).clamp(_minScale, _maxScale);
    final scene = (_focalAtStart - _panAtStart) / _scaleAtStart;
    setState(() {
      _scale = next;
      _pan = focal - scene * next;
    });
  }

  void _onScaleStart(ScaleStartDetails details) {
    _panAtStart = _pan;
    _scaleAtStart = _scale;
    _focalAtStart = details.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) =>
      _applyZoom(details.localFocalPoint, details.scale);

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

  /// Where each card is, by what it says it is — what an arrow's hold is
  /// resolved against.
  ///
  /// Two cards can say the same thing, in which case the first wins. That is
  /// the same rule the positions use, and the cost of it is an arrow pointing
  /// at whichever of two identical notes came first, which is not worth a
  /// second naming scheme to avoid.
  Map<String, Rect> get _cardRects {
    final rects = <String, Rect>{};
    final drawable = math.min(widget.cards.length, _spots.length);
    for (var i = 0; i < drawable; i++) {
      rects.putIfAbsent(widget.cards[i].ref, () => _sceneRect(i));
    }
    return rects;
  }

  /// What an arrow may take hold of: everything except the frames.
  ///
  /// A frame is the space several things stand in, so an arrow dropped inside
  /// one was taking hold of the frame and snapping out to its edge — pointing
  /// at the room rather than at anything in it. Holds are still *resolved*
  /// against every card, frames included, so an arrow drawn before this
  /// keeps whatever it was holding.
  Map<String, Rect> get _holdTargets {
    final rects = <String, Rect>{};
    final drawable = math.min(widget.cards.length, _spots.length);
    for (var i = 0; i < drawable; i++) {
      if (_spots[i].isFrame) continue;
      rects.putIfAbsent(widget.cards[i].ref, () => _sceneRect(i));
    }
    return rects;
  }

  /// The sticky notes sitting on top of [index].
  ///
  /// A note put on a photograph is about that photograph, so moving the
  /// photograph takes the note with it. Worked out from where things are
  /// rather than recorded anywhere: a note is stuck to whatever it is sitting
  /// on at the moment you pick that thing up, which is what "stuck to it"
  /// means to a person and needs nothing written in the file.
  Set<int> _stuckOn(int index) {
    if (_spots[index].isFrame) return const {};
    final bounds = _sceneRect(index);

    return {
      for (var i = 0; i < _spots.length; i++)
        if (i != index &&
            _spots[i].kind == CanvasSpotKind.sticky &&
            bounds.contains(_sceneRect(i).center))
          i,
    };
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
    // And a sticky note sitting on something comes along when that thing is
    // picked up. After the frames, so a note on a photograph in a frame is
    // caught whichever of the two was grabbed.
    for (final at in moving.toList()) {
      moving = {...moving, ..._stuckOn(at)};
    }
    // A mark drawn inside a frame belongs to what is in the frame, so it
    // travels with it — a pen note beside a photograph is about that
    // photograph, and leaving it behind pulls the two apart.
    _marksRiding.clear();
    _marksShift = Offset.zero;
    for (final at in moving) {
      if (!_spots[at].isFrame) continue;
      final bounds = _sceneRect(at);
      for (var i = 0; i < widget.shapes.length; i++) {
        if (_marksRiding.containsKey(i)) continue;
        final points = CanvasMarks.pointsOf(widget.shapes[i], _cardRects);
        if (CanvasMarks.within(points, bounds)) {
          _marksRiding[i] = points;
        }
      }
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
    _commitRidingMarks();
    _dragFrom.clear();
    _dragRaw = Offset.zero;
    if (_guides.isNotEmpty) setState(() => _guides = const []);
  }

  /// Writes out the marks that rode along with a frame, once the drag is
  /// over and it is known how far they went.
  void _commitRidingMarks() {
    final riding = {..._marksRiding};
    final shift = _marksShift;
    setState(() {
      _marksRiding.clear();
      _marksShift = Offset.zero;
    });
    if (riding.isEmpty || shift == Offset.zero) return;

    for (final entry in riding.entries) {
      if (entry.key >= widget.shapes.length) continue;
      widget.onEditShape?.call(
        entry.key,
        widget.shapes[entry.key].copyWith(
          points: CanvasMarks.shifted(entry.value, shift),
          // A mark that moved with a frame is where it was put, so an end
          // that was holding a card lets go rather than springing back.
          clearFrom: true,
          clearTo: true,
        ),
      );
    }
  }

  /// Moves [index], and everything selected with it — dragging one of a group
  /// takes the group, which is the point of picking several.
  void _moveBy(int index, Offset delta) {
    if (_dragFrom.isEmpty) _beginDrag(index);
    final moving = _dragFrom.keys.toList();
    if (moving.isEmpty) return;

    _dragRaw += Offset(delta.dx / _scale, delta.dy / _scale);
    if (_marksRiding.isNotEmpty) _marksShift = _dragRaw;

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

    final modified = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (modified && event.logicalKey == LogicalKeyboardKey.keyC) {
      if (_selection.length != 1) return KeyEventResult.ignored;
      final index = _selection.single;
      if (!widget.cards[index].isImage) return KeyEventResult.ignored;
      _withFile(index, ImageActions.copy);
      return KeyEventResult.handled;
    }

    final box = _viewport.currentContext?.findRenderObject() as RenderBox?;
    final centre = box == null
        ? Offset.zero
        : Offset(box.size.width / 2, box.size.height / 2);

    switch (event.logicalKey) {
      case LogicalKeyboardKey.keyC:
      case LogicalKeyboardKey.keyN:
      case LogicalKeyboardKey.keyL:
      case LogicalKeyboardKey.keyS:
      case LogicalKeyboardKey.keyO:
        if (modified || HardwareKeyboard.instance.isAltPressed) {
          return KeyEventResult.ignored;
        }
        final tool = switch (event.logicalKey) {
          LogicalKeyboardKey.keyC => CanvasTool.sticky,
          LogicalKeyboardKey.keyN => CanvasTool.text,
          LogicalKeyboardKey.keyL => _lastLineTool,
          LogicalKeyboardKey.keyS => CanvasTool.rectangle,
          _ => CanvasTool.oval,
        };
        _chooseTool(tool);
        return KeyEventResult.handled;
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
        if (modified || HardwareKeyboard.instance.isAltPressed) {
          return KeyEventResult.ignored;
        }
        if (HardwareKeyboard.instance.isShiftPressed) {
          fit();
        } else {
          _chooseTool(CanvasTool.frame);
        }
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
        if (_selection.isEmpty && _picked == null) {
          return KeyEventResult.ignored;
        }
        setState(() {
          _selection.clear();
          _picked = null;
        });
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyI:
        if (!modified) {
          if (HardwareKeyboard.instance.isAltPressed) {
            return KeyEventResult.ignored;
          }
          widget.onAddImage?.call(null);
          return widget.onAddImage == null
              ? KeyEventResult.ignored : KeyEventResult.handled;
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
    // The picked mark's nodes, worked out once: the handles are drawn from
    // them and there can be a dozen.
    final picked = _picked != null && _picked! < widget.shapes.length
        ? _picked
        : null;
    final nodes = picked == null
        ? const <double>[]
        : CanvasMarks.pointsOf(widget.shapes[picked], _cardRects);

    final drawing =
        widget.onDrawShape != null &&
        (_tool.drags || _tool == CanvasTool.eraser);

    // With any tool in hand a card stops taking the press — not just a
    // drawing one. A sticky note or a caption dropped onto a picture was
    // picking the picture up instead, so it looked as though the tool only
    // worked on empty canvas.
    final armed = _tool != CanvasTool.select;

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
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Kept for the next build rather than used in this one: a
                // card being near the screen only has to be right by the
                // time it decides whether to fetch, and reading it here
                // avoids measuring the board from inside every card.
                _viewportSize = constraints.biggest;
                return Stack(
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
                      child: MouseRegion(
                        // Only while an arrow is in hand: nothing else on the
                        // canvas cares where the pointer is between gestures, and
                        // a rebuild for every mouse move is not free.
                        onHover: _tool.draws == CanvasShapeKind.arrow
                            ? (event) =>
                                  setState(() => _pointer = event.localPosition)
                            : null,
                        onExit: _tool.draws == CanvasShapeKind.arrow
                            ? (_) => setState(() => _pointer = null)
                            : null,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          // From where the pointer went down, not from where the
                          // drag was recognised. The default swallows the first
                          // eighteen pixels as slop, which on a card read as lag
                          // and here is worse: a shape drawn from a corner
                          // started short of it, and a frame came out smaller
                          // than the box that was dragged out for it.
                          dragStartBehavior: DragStartBehavior.down,
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
                            setState(() {
                              _selection.clear();
                              _picked = null;
                            });
                          },
                          // A mark is not a card, so it has no box to press on:
                          // the press lands on the canvas and the mark under it
                          // has to be looked for.
                          onSecondaryTapUp: (details) {
                            final scene = _toScene(details.localPosition);
                            final mark = _markNear(scene);
                            if (mark == null) {
                              _showEmptyMenu(scene, details.globalPosition);
                            } else {
                              _showMarkMenu(mark, scene, details.globalPosition);
                            }
                          },
                          onLongPressStart: (details) {
                            final scene = _toScene(details.localPosition);
                            final mark = _markNear(scene);
                            if (mark == null) return;
                            _showMarkMenu(mark, scene, details.globalPosition);
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
                          onScaleStart: touch && !drawing
                              ? _onScaleStart
                              : null,
                          onScaleUpdate: touch && !drawing
                              ? _onScaleUpdate
                              : null,
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
                              colour: theme.colorScheme.outlineVariant,
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
                        enabled: !armed,
                        pan: _pan,
                        scale: _scale,
                        slug: widget.slug,
                        cardKey: _cardKeys.putIfAbsent(index, GlobalKey.new),
                        selected: _selection.contains(index),
                        touch: touch,
                        onPan: (delta) => setState(() => _pan += delta),
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
                          _dragFocal = null;
                          _endDrag();
                          _commit();
                        },
                        onDragAnchor: (at) => _dragFocal = at,
                        onDragTo: (at) {
                          final from = _dragFocal;
                          if (from == null) return;
                          _dragFocal = at;
                          _moveBy(index, at - from);
                        },
                        onPinchStart: touch ? _pinchStart : null,
                        onPinchUpdate: touch ? _pinchUpdate : null,
                        near: _nearViewport(_spots[index]),
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
                            pendingKind: _tool == CanvasTool.frame
                                ? CanvasShapeKind.rectangle
                                : _tool.draws,
                            pendingColour: _colour,
                            pendingThickness: _thickness,
                            pendingCurved: _tool == CanvasTool.bendyArrow ||
                                (_tool == CanvasTool.pen &&
                                    _smoothPen &&
                                    (_drawing?.length ?? 0) >= 6),
                            pan: _pan,
                            scale: _scale,
                            theme: theme,
                            rubbed: _rubbed,
                            cards: _cardRects,
                            riding: _marksRiding.keys.toSet(),
                            shift: _marksShift,
                          ),
                        ),
                      ),
                    ),
                    // The nodes of the picked mark, each one a handle you can
                    // drag. Real widgets rather than paint, because a node is
                    // something you take hold of.
                    if (picked != null)
                      for (var node = 0; node < nodes.length ~/ 2; node++)
                        _NodeHandle(
                          key: ValueKey('node-${widget.section}-$picked-$node'),
                          at:
                              Offset(nodes[node * 2], nodes[node * 2 + 1]) *
                                  _scale +
                              _pan,
                          colour: theme.colorScheme.tertiary,
                          onMove: (delta) => _moveNode(picked, node, delta),
                          onRemove: () => widget.onEditShape?.call(
                            picked,
                            widget.shapes[picked].copyWith(
                              points: CanvasMarks.withoutNode(nodes, node),
                            ),
                          ),
                        ),
                    // What an arrow would take hold of, while one is in hand.
                    if (_tool.draws == CanvasShapeKind.arrow && _pointer != null)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: _HoldsPainter(
                              hold: _holdNear(_toScene(_pointer!)),
                              pan: _pan,
                              scale: _scale,
                              colour: theme.colorScheme.tertiary,
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
                              border: Border.all(
                                color: theme.colorScheme.primary,
                              ),
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
                            onTool: _chooseTool,
                            onColour: (colour) =>
                                setState(() => _colour = colour),
                            thickness: _thickness,
                            onThickness: (value) =>
                                setState(() => _thickness = value),
                            smoothPen: _smoothPen,
                            onSmoothPen: (value) =>
                                setState(() => _smoothPen = value),
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
                );
              },
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

  /// The last size the board was drawn at, so a card can be told whether it
  /// is worth fetching a picture for before the frame is laid out.
  Size _viewportSize = Size.zero;

  /// How far outside the screen a picture is still worth having: one screen
  /// in every direction, so scrolling or zooming out a little finds pictures
  /// already there rather than a row of grey boxes.
  static const _eagerMargin = 1.0;

  /// Whether a card is close enough to the screen to be worth fetching.
  ///
  /// A board with thirty pictures on it fetched all thirty the moment it
  /// opened, which on a phone is a lot of waiting for pictures that are not
  /// on screen. Anything without a size yet counts as near: a picture whose
  /// height is unknown has never loaded, and refusing to load it is how it
  /// would stay unknown.
  bool _nearViewport(CanvasSpot spot) {
    if (_viewportSize == Size.zero) return true;

    final at = Offset(spot.x, spot.y) * _scale + _pan;
    final width = spot.width * _scale;
    final height = (spot.height ?? spot.width) * _scale;
    final margin = Offset(
      _viewportSize.width * _eagerMargin,
      _viewportSize.height * _eagerMargin,
    );

    return at.dx + width >= -margin.dx &&
        at.dy + height >= -margin.dy &&
        at.dx <= _viewportSize.width + margin.dx &&
        at.dy <= _viewportSize.height + margin.dy;
  }

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
          // Drawn in the colour it names: a menu of colours whose entries are
          // all the same grey circle is just a list of words.
          tint: option == CanvasColour.none
              ? null
              : canvasColourOf(option, Theme.of(context)),
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
    if (!mounted) return null;
    return context.read<AppState>().attachmentFor(path);
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
    required this.touch,
    required this.onPan,
    required this.cardKey,
    required this.onGrab,
    required this.onMenu,
    required this.onMove,
    required this.onRotate,
    required this.onResize,
    required this.onRelease,
    required this.onDragAnchor,
    required this.onDragTo,
    this.onPinchStart,
    this.onPinchUpdate,
    this.near = true,
    this.enabled = true,
  });

  final CanvasCard card;
  final CanvasSpot spot;
  final Offset pan;
  final double scale;
  final String slug;
  final bool selected;
  final bool touch;
  final ValueChanged<Offset> onPan;

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

  /// False while a drawing tool is armed. A card is a thing you pick up, but
  /// with a pen or an arrow in hand a press on it is a mark being drawn over
  /// it — otherwise an arrow could never start or finish on a picture, which
  /// is the one place an arrow most wants to go.
  final bool enabled;

  /// A pinch that began on this card, in global coordinates.
  ///
  /// It has to be handed up rather than left to the canvas underneath. The
  /// card wins the gesture the moment a finger lands on it, so the canvas
  /// never sees the second finger: pinching over a picture dragged the
  /// picture about and did not zoom at all.
  final void Function(Offset focal)? onPinchStart;
  final void Function(Offset focal, double scale)? onPinchUpdate;

  /// Whether this card is close enough to the screen for its picture to be
  /// worth fetching yet.
  final bool near;

  /// Where a one-finger drag started and where it has reached, in global
  /// coordinates. The canvas turns them into movement, so the slop the
  /// recogniser swallowed before its first update is not lost.
  final ValueChanged<Offset> onDragAnchor;
  final ValueChanged<Offset> onDragTo;

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
      child: IgnorePointer(
        ignoring: !enabled,
        child: Transform.rotate(
          angle: spot.rotation * math.pi / 180,
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(
              spot.flipX ? -1 : 1,
              spot.flipY ? -1 : 1,
              1,
            ),
            // The raw touch, before any recogniser has decided anything.
            // A scale recogniser only starts once the slop is crossed, so
            // its first report is already twenty pixels along; anchoring the
            // drag here instead keeps the card under the finger from the
            // moment it lands.
            child: Listener(
              onPointerDown: (event) => onDragAnchor(event.position),
              child: GestureDetector(
                // A frame answers only where its title is. Its body is the
                // space other things stand in, so a press in the middle of one
                // belongs to the canvas — to a pinch that means to zoom, to a
                // marquee that means to select what is standing there. A frame
                // covers half the board, and one that swallowed every press
                // made that half of the board unusable.
                behavior: spot.isFrame
                    ? HitTestBehavior.deferToChild
                    : HitTestBehavior.opaque,
                // From the moment it is touched, not from where the drag was
                // recognised: the default loses the first eighteen pixels of every
                // drag to the slop, which on a canvas reads as the card lagging
                // behind the finger before it catches up.
                dragStartBehavior: DragStartBehavior.down,
                // Scale rather than pan, because one recogniser has to handle
                // both: a second finger on a card means zoom the board, and a
                // pan recogniser cannot tell that it has happened.
                onScaleStart: (details) {
                  if (details.pointerCount > 1) {
                    onPinchStart?.call(details.focalPoint);
                    return;
                  }
                  // On touch, an unselected card is part of the surface.
                  // Tap it first to pick it up for a later drag.
                  if (!touch || selected) onGrab();
                },
                onScaleUpdate: (details) {
                  if (details.pointerCount > 1) {
                    onPinchUpdate?.call(details.focalPoint, details.scale);
                    return;
                  }
                  if (touch && !selected) {
                    onPan(details.focalPointDelta);
                  } else {
                    onDragTo(details.focalPoint);
                  }
                },
                onScaleEnd: (_) {
                  if (!touch || selected) onRelease();
                },
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
                    IgnorePointer(
                      ignoring: spot.isFrame,
                      child: Container(
                        decoration: BoxDecoration(
                          color: spot.isFrame
                              // Barely there: a frame is a boundary, not a panel,
                              // and what stands on it has to stay readable.
                              ? theme.colorScheme.surfaceContainerHighest
                                    .withValues(alpha: 0.35)
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
                              // Nothing: a frame's name is drawn as a handle
                              // beside it, because the name is the one part of a
                              // frame you are meant to be able to take hold of.
                              ? const SizedBox.shrink()
                              : card.isImage
                              ? _CanvasImage(
                                  reference: card.imagePath!,
                                  near: near,
                                )
                              // The writing is scaled with the canvas, not left
                              // at its own size. A card's box is drawn at
                              // width × zoom, so text that did not scale kept
                              // full-size glyphs in a shrinking box: zoomed out,
                              // a sticky note wrapped to one letter a line and
                              // stretched into a ribbon.
                              //
                              // Scaled through the text scaler rather than by
                              // transforming the widget, so the glyphs are laid
                              // out at the size they are drawn and stay crisp.
                              : MediaQuery(
                                  data: MediaQuery.of(context).copyWith(
                                    textScaler: _ZoomedText(
                                      MediaQuery.textScalerOf(context),
                                      scale.clamp(0.2, 4.0),
                                    ),
                                  ),
                                  child: Padding(
                                    padding: EdgeInsets.all(
                                      // A note is a label written on a square, so
                                      // it wants air around it; an ordinary card
                                      // is writing and wants the room for it.
                                      (spot.kind == CanvasSpotKind.sticky
                                              ? 12
                                              : 8) *
                                          scale.clamp(0.5, 1.5),
                                    ),
                                    child: NoteView(
                                      markdown: card.markdown,
                                      // Centred on a sticky note, the way one
                                      // written by hand is: what is on it is a
                                      // label, not a paragraph. Everything else
                                      // stays left, where writing belongs.
                                      align: spot.kind == CanvasSpotKind.sticky
                                          ? WrapAlignment.center
                                          : null,
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    ),
                    // A frame's name, and the one part of it you take hold of.
                    if (spot.isFrame)
                      Positioned(
                        left: 0,
                        top: 0,
                        child: Container(
                          constraints: BoxConstraints(
                            maxWidth: math.max(40, spot.width * scale),
                          ),
                          padding: EdgeInsets.symmetric(
                            horizontal: 8 * scale.clamp(0.6, 1.4),
                            vertical: 4 * scale.clamp(0.6, 1.4),
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(4),
                              bottomRight: Radius.circular(6),
                            ),
                            border: Border.all(
                              color: selected
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.outlineVariant,
                            ),
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
                                .apply(fontSizeFactor: scale.clamp(0.6, 1.4)),
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
        ),
      ),
    );
  }
}

/// The canvas's zoom applied on top of whatever text size the person has
/// asked their device for.
///
/// Composed rather than replaced: a canvas zoomed to a half should halve the
/// writing on it, but it has no business undoing someone's larger-text
/// setting on the way.
class _ZoomedText extends TextScaler {
  const _ZoomedText(this.base, this.zoom);

  final TextScaler base;
  final double zoom;

  @override
  double scale(double fontSize) => base.scale(fontSize) * zoom;

  // Still required by the base class, though nothing should be reading a
  // single factor now that scaling is allowed to be nonlinear.
  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => base.textScaleFactor * zoom;

  @override
  bool operator ==(Object other) =>
      other is _ZoomedText && other.base == base && other.zoom == zoom;

  @override
  int get hashCode => Object.hash(base, zoom);
}

/// A picture on the canvas, at whatever width the card is.
class _CanvasImage extends StatefulWidget {
  const _CanvasImage({required this.reference, this.near = true});

  final String reference;

  /// False while the card is far enough off screen that its picture is not
  /// worth fetching. A board of thirty pictures fetched all thirty the
  /// moment it opened, most of them for nothing.
  final bool near;

  @override
  State<_CanvasImage> createState() => _CanvasImageState();
}

class _CanvasImageState extends State<_CanvasImage> {
  Future<File?>? _file;

  /// The sync this picture was last asked for at, so a failure can be tried
  /// again once something has happened that might have fixed it.
  int _askedAt = -1;

  /// Whether the last attempt came back with nothing.
  bool _missing = false;

  Future<File?> _load(AppState state) {
    _askedAt = state.syncGeneration;
    _missing = false;
    final pending = state.attachmentFor(widget.reference).then((file) {
      if (mounted && file == null) _missing = true;
      return file;
    });
    return _file = pending;
  }

  @override
  void didUpdateWidget(_CanvasImage old) {
    super.didUpdateWidget(old);
    // Cards shift along as others are added, so the same widget can be handed
    // a different picture. Keeping the first answer showed the wrong one.
    if (old.reference != widget.reference) _file = null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<AppState>();

    if (widget.near &&
        (_file == null || (_missing && state.syncGeneration != _askedAt))) {
      _load(state);
    }

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
    required this.pendingThickness,
    required this.pendingCurved,
    required this.pan,
    required this.scale,
    required this.theme,
    required this.rubbed,
    required this.cards,
    this.riding = const {},
    this.shift = Offset.zero,
  });

  final List<CanvasShape> shapes;

  /// The mark being drawn this moment, which is not in [shapes] yet.
  final List<double>? pending;
  final CanvasShapeKind? pendingKind;
  final CanvasColour pendingColour;
  final double pendingThickness;
  final bool pendingCurved;

  final Offset pan;
  final double scale;
  final ThemeData theme;

  /// What the eraser has passed over, drawn faintly so that letting go is not
  /// a surprise.
  final Set<int> rubbed;

  /// Where each card is, so an arrow held to one is drawn at the card rather
  /// than where it was first dragged.
  final Map<String, Rect> cards;

  /// Marks travelling with a frame that is mid-drag, and how far it has got.
  /// Drawn moved without being written, so they keep up with the frame
  /// without the file being rewritten on every frame of the drag.
  final Set<int> riding;
  final Offset shift;

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
    double opacity, {
    bool curved = false,
  }) {
    if (points.length < 4) return;

    final paint = Paint()
      ..color = _colourOf(colour).withValues(alpha: opacity)
      ..strokeWidth = math.max(1, thickness * scale)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    // In viewport coordinates, so the curve is fitted to what is on screen
    // and its bow does not grow with the zoom.
    final onGlass = [
      for (var i = 0; i < points.length ~/ 2; i++) ...[
        _at(points, i).dx,
        _at(points, i).dy,
      ],
    ];
    final last = points.length ~/ 2 - 1;

    switch (kind) {
      case CanvasShapeKind.line:
        canvas.drawPath(
          CanvasMarks.pathThrough(onGlass, curved: curved),
          paint,
        );
      case CanvasShapeKind.arrow:
        canvas.drawPath(
          CanvasMarks.pathThrough(onGlass, curved: curved),
          paint,
        );
        // Pointed along the last stretch of the line, which for a curve is
        // the tangent it arrives on rather than the straight line from where
        // it started.
        _head(canvas, onGlass, curved, paint);
      case CanvasShapeKind.rectangle:
        canvas.drawRect(
          Rect.fromPoints(_at(points, 0), _at(points, last)),
          paint,
        );
      case CanvasShapeKind.oval:
        canvas.drawOval(
          Rect.fromPoints(_at(points, 0), _at(points, last)),
          paint,
        );
      case CanvasShapeKind.stroke:
        canvas.drawPath(
          CanvasMarks.pathThrough(onGlass, curved: curved),
          paint,
        );
    }
  }

  /// A plain two-stroke head, sized on the glass so an arrow does not grow a
  /// spearhead when the board is zoomed in.
  ///
  /// The size comes from the arrow's own length, not from the two points its
  /// direction was worked out between — reading it off those is what once
  /// left every head half a pixel long, and so invisible.
  void _head(Canvas canvas, List<double> onGlass, bool curved, Paint paint) {
    final length = CanvasMarks.headLength(
      CanvasMarks.lengthOf(onGlass, curved: curved),
    );
    if (length <= 0) return;

    final angle = CanvasMarks.tipAngle(onGlass, curved: curved);
    final count = onGlass.length ~/ 2;
    final tip = Offset(onGlass[(count - 1) * 2], onGlass[(count - 1) * 2 + 1]);
    const spread = 0.5;

    for (final side in [-spread, spread]) {
      canvas.drawLine(
        tip,
        tip -
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
      final points = CanvasMarks.pointsOf(shape, cards);
      _draw(
        canvas,
        shape.kind,
        riding.contains(i) ? CanvasMarks.shifted(points, shift) : points,
        shape.colour,
        shape.thickness,
        rubbed.contains(i) ? 0.2 : 1,
        curved: shape.curved,
      );
    }

    final drawing = pending;
    if (drawing != null && pendingKind != null) {
      _draw(
        canvas,
        pendingKind!,
        drawing,
        pendingColour,
        pendingThickness,
        0.7,
        curved: pendingCurved,
      );
    }
  }

  @override
  bool shouldRepaint(_MarksPainter old) => true;
}

/// One node of a mark, as something you can take hold of.
///
/// Drawn where the node is and dragged from where it is pressed, so a node
/// does not jump eighteen pixels before it starts to follow. Double-tapping
/// takes it out, which is the other half of adding one.
class _NodeHandle extends StatelessWidget {
  const _NodeHandle({
    super.key,
    required this.at,
    required this.colour,
    required this.onMove,
    required this.onRemove,
  });

  final Offset at;
  final Color colour;
  final ValueChanged<Offset> onMove;
  final VoidCallback onRemove;

  static const _size = 14.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Positioned(
      left: at.dx - _size / 2,
      top: at.dy - _size / 2,
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onPanUpdate: (details) => onMove(details.delta),
          onDoubleTap: onRemove,
          child: Container(
            width: _size,
            height: _size,
            decoration: BoxDecoration(
              color: colour,
              shape: BoxShape.circle,
              border: Border.all(color: theme.colorScheme.onPrimary, width: 2),
            ),
          ),
        ),
      ),
    );
  }
}

/// The places an arrow can take hold, while one is being drawn.
///
/// Snapping you cannot see is snapping you find out about afterwards, when
/// the arrow has landed somewhere you did not ask for. This draws the nine
/// holds on the card under the pointer and fills in the one that would be
/// taken, so the snap is something you watch happen.
class _HoldsPainter extends CustomPainter {
  _HoldsPainter({
    required this.hold,
    required this.pan,
    required this.scale,
    required this.colour,
  });

  final ({Rect card, Offset at})? hold;
  final Offset pan;
  final double scale;
  final Color colour;

  Offset _at(Offset scene) => scene * scale + pan;

  @override
  void paint(Canvas canvas, Size size) {
    final near = hold;
    if (near == null) return;

    final outline = Paint()
      ..color = colour.withValues(alpha: 0.7)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final filled = Paint()..color = colour;

    for (final place in CanvasMarks.holds) {
      final scene = Offset(
        near.card.left + near.card.width * place.dx,
        near.card.top + near.card.height * place.dy,
      );
      final point = _at(scene);
      // Measured on the glass, like the background dots, so the ring is the
      // same target however far the canvas is zoomed.
      final taken = (scene - near.at).distance < 0.01;
      canvas.drawCircle(point, taken ? 6 : 4, taken ? filled : outline);
    }
  }

  @override
  bool shouldRepaint(_HoldsPainter old) =>
      old.hold != hold ||
      old.pan != pan ||
      old.scale != scale ||
      old.colour != colour;
}

/// What the next press on the canvas will do.
enum CanvasTool {
  select,
  sticky,
  text,
  frame,
  line,
  arrow,
  bendyArrow,
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
    CanvasTool.bendyArrow => 'Bendy arrow',
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
    CanvasTool.bendyArrow => Icons.gesture,
    CanvasTool.rectangle => Icons.crop_square,
    CanvasTool.oval => Icons.circle_outlined,
    CanvasTool.pen => Icons.draw_outlined,
    CanvasTool.eraser => Icons.auto_fix_normal,
  };

  /// Placed by pressing once and saying what it says.
  bool get places => this == CanvasTool.sticky || this == CanvasTool.text;

  /// Worked by dragging something out rather than by pressing once. A frame
  /// is a box you draw, the way it is in every tool that has frames — its
  /// size is the point of it, so asking for one by a press and then handing
  /// back a guess was the wrong shape of gesture.
  bool get drags => draws != null || this == CanvasTool.frame;

  /// Drawn by dragging, rather than placed by pressing.
  CanvasShapeKind? get draws => switch (this) {
    CanvasTool.line => CanvasShapeKind.line,
    CanvasTool.arrow => CanvasShapeKind.arrow,
    CanvasTool.bendyArrow => CanvasShapeKind.arrow,
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
/// Shapes and lines each have a menu, keeping the column compact.
class _CanvasTools extends StatelessWidget {
  const _CanvasTools({
    required this.tool,
    required this.colour,
    required this.onTool,
    required this.onColour,
    required this.thickness,
    required this.onThickness,
    required this.smoothPen,
    required this.onSmoothPen,
  });

  final CanvasTool tool;
  final CanvasColour colour;
  final ValueChanged<CanvasTool> onTool;
  final ValueChanged<CanvasColour> onColour;
  final double thickness;
  final ValueChanged<double> onThickness;
  final bool smoothPen;
  final ValueChanged<bool> onSmoothPen;

  /// Fine, ordinary and bold. Three weights rather than a slider: a slider
  /// in a column this narrow is a thing to fight with, and nobody has ever
  /// wanted a line exactly 3.4 wide.
  static const _weights = [1.0, 2.0, 5.0];

  static const _lines = [
    CanvasTool.line,
    CanvasTool.arrow,
    CanvasTool.bendyArrow,
  ];

  static const _shapes = [
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
    final shape = _shapes.contains(tool) ? tool : CanvasTool.rectangle;
    final line = _lines.contains(tool) ? tool : CanvasTool.arrow;

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
            PopupMenuButton<CanvasTool>(
              tooltip: 'Lines',
              position: PopupMenuPosition.under,
              iconSize: 18,
              icon: Icon(line.icon, size: 18,
                color: _lines.contains(tool) ? theme.colorScheme.primary : null),
              onSelected: onTool,
              itemBuilder: (_) => [
                for (final option in _lines)
                  PopupMenuItem(
                    value: option,
                    child: Row(children: [
                      Icon(option.icon, size: 18),
                      const SizedBox(width: 10),
                      Text(option.label),
                    ]),
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
            if (tool == CanvasTool.pen)
              IconButton(
                tooltip: smoothPen ? 'Smooth pen on' : 'Smooth pen off',
                visualDensity: VisualDensity.compact,
                isSelected: smoothPen,
                selectedIcon: Icon(Icons.auto_fix_high,
                    size: 18, color: theme.colorScheme.primary),
                icon: const Icon(Icons.auto_fix_high, size: 18),
                onPressed: () => onSmoothPen(!smoothPen),
              ),
            // Only while something is being drawn, since a note has no
            // stroke to weigh.
            if (tool.draws != null) ...[
              const Divider(height: 8, indent: 6, endIndent: 6),
              for (final weight in _weights)
                Tooltip(
                  message: switch (weight) {
                    1.0 => 'Fine',
                    5.0 => 'Bold',
                    _ => 'Ordinary',
                  },
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => onThickness(weight),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 4,
                      ),
                      child: Container(
                        width: 16,
                        height: weight + 2,
                        decoration: BoxDecoration(
                          color: weight == thickness
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
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

    // Measured on the glass rather than in the scene, so the background
    // stays visible however far out the canvas is zoomed.
    final step = CanvasMarks.backgroundStep(scale);
    if (step <= 0) return;

    final paint = Paint()
      ..color = colour
      ..strokeWidth = 1;

    if (style == CanvasBackground.dots) {
      // Measured on the glass, not in the scene, so a dot is the same mark at
      // every zoom instead of a speck when you are out and a blob when in.
      const radius = 1.5;
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
