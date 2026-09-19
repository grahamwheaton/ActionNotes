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
  });

  final String slug;
  final String section;
  final List<CanvasCard> cards;

  /// One per card, in the same order.
  final List<CanvasSpot> spots;

  /// Fires with the new positions when something is moved or resized.
  final ValueChanged<List<CanvasSpot>> onChanged;

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
  int? _selected;

  /// Pan and scale as the current gesture started, for a pinch.
  Offset _panAtStart = Offset.zero;
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

  void _bringToFront(int index) {
    var top = 0;
    for (final spot in _spots) {
      if (spot.z > top) top = spot.z;
    }
    if (_spots[index].z == top && top != 0) return;
    setState(() => _spots[index] = _spots[index].copyWith(z: top + 1));
  }

  void _moveBy(int index, Offset delta) {
    setState(() {
      final spot = _spots[index];
      _spots[index] = spot.copyWith(
        x: spot.x + delta.dx / _scale,
        y: spot.y + delta.dy / _scale,
      );
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
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
                    setState(() => _selected = null);
                  },
                  onScaleStart: _onScaleStart,
                  onScaleUpdate: _onScaleUpdate,
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
                  selected: _selected == index,
                  onGrab: () {
                    _focus.requestFocus();
                    _active = index;
                    _bringToFront(index);
                    setState(() => _selected = index);
                  },
                  onMove: (delta) => _moveBy(index, delta),
                  onResize: (delta) => _resizeBy(index, delta),
                  onRelease: () {
                    _active = null;
                    _commit();
                  },
                ),
              Positioned(
                right: 8,
                bottom: 8,
                child: _CanvasControls(
                  scale: _scale,
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
    required this.onGrab,
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
  final VoidCallback onGrab;
  final ValueChanged<Offset> onMove;
  final ValueChanged<Offset> onResize;
  final VoidCallback onRelease;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final at = Offset(spot.x, spot.y) * scale + pan;

    return Positioned(
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
  });

  final double scale;
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
