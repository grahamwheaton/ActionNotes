import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:provider/provider.dart';

import '../markdown/canvas_cards.dart';
import '../markdown/canvas_placement.dart';
import '../models/project.dart';
import '../models/canvas_layout.dart';
import '../state/app_state.dart';
import '../storage/canvas_export.dart';
import 'canvas_view.dart';
import 'checklist_view.dart';

/// A canvas on a screen of its own.
///
/// The panel inside a project is enough to see what is on a canvas; arranging
/// one wants the whole window, which is the difference between a picture of a
/// moodboard and a moodboard. Nothing here is a second copy of the canvas —
/// it reads the same section and the same layout, so what is moved on either
/// is moved on both.
class CanvasScreen extends StatefulWidget {
  const CanvasScreen({super.key, required this.slug, required this.section});

  final String slug;
  final String section;

  static Future<void> open(
    BuildContext context, {
    required String slug,
    required String section,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CanvasScreen(slug: slug, section: section),
      ),
    );
  }

  @override
  State<CanvasScreen> createState() => _CanvasScreenState();
}

class _CanvasScreenState extends State<CanvasScreen> {
  String get slug => widget.slug;
  String get section => widget.section;

  bool _dropping = false;
  int _pendingImages = 0;
  final List<Offset> _pendingPositions = [];
  final _canvas = GlobalKey<CanvasViewState>();

  /// Wrapped round the board so it can be drawn to an image — which is what
  /// both exports are built from.
  final _board = GlobalKey();

  /// Adds one image from bytes already in hand — a paste, or a dropped file.
  Future<void> _addBytes(String name, List<int> bytes, {Offset? at}) async {
    final state = context.read<AppState>();
    final centre = at ?? _canvas.currentState?.sceneAtViewportCentre() ??
        Offset(MediaQuery.sizeOf(context).width / 2, MediaQuery.sizeOf(context).height / 2);
    // Show a card while the attachment is uploading, which may take seconds.
    setState(() {
      _pendingImages++;
      _pendingPositions.add(centre);
    });
    try {
      final reference = await state.attachImage(slug, fileName: name, bytes: bytes);
      if (reference == null || !mounted) return;
      await state.placeCanvasCard(slug, section,
        markdown: reference,
        spot: CanvasSpot(x: centre.dx - 130, y: centre.dy - 100, width: 260),
      );
    } finally {
      if (mounted) setState(() {
        _pendingImages--;
        _pendingPositions.remove(centre);
      });
    }
  }

  /// Ctrl+V puts whatever is on the clipboard onto the canvas.
  Future<void> _paste() async {
    final image = await Pasteboard.image;
    if (image != null && image.isNotEmpty) {
      final stamp = DateTime.now().toUtc().toIso8601String().split('.').first;
      await _addBytes(
        'pasted-${stamp.replaceAll(RegExp('[:-]'), '')}.png',
        image,
      );
      return;
    }

    // No picture on the clipboard: text becomes a note card, which is what
    // pasting a quote or a link onto a board should do.
    if (!mounted) return;
    final text = await Clipboard.getData(Clipboard.kTextPlain);
    final value = text?.text?.trim();
    if (value == null || value.isEmpty || !mounted) return;
    await context.read<AppState>().addCanvasCard(slug, section, value);
  }

  /// The board drawn to a picture, at a little over screen resolution so it
  /// is worth looking at rather than a screenshot of a screenshot.
  ///
  /// What is on screen, which is the honest thing to export: a canvas is
  /// where things sit relative to each other, and that is exactly what you
  /// have arranged. Fit the board first if you want all of it.
  Future<({Uint8List bytes, int width, int height})?> _drawBoard() async {
    final boundary =
        _board.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;

    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      return (
        bytes: data.buffer.asUint8List(),
        width: image.width,
        height: image.height,
      );
    } finally {
      image.dispose();
    }
  }

  Future<void> _exportPdf() async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final title = state.projectBySlug(slug)?.title ?? 'Canvas';

    final drawn = await _drawBoard();
    if (drawn == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('The canvas could not be drawn.')),
      );
      return;
    }

    final location = await getSaveLocation(
      suggestedName: CanvasExport.fileNameFor(title, section, extension: 'pdf'),
    );
    if (location == null) return;

    final pdf = await CanvasExport.pdfOf(
      board: drawn.bytes,
      width: drawn.width,
      height: drawn.height,
    );
    await File(location.path).writeAsBytes(pdf);
    messenger.showSnackBar(
      SnackBar(content: Text('Saved to ${location.path}')),
    );
  }

  Future<void> _exportImages() async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);

    final block = state
        .projectBySlug(slug)
        ?.blocks
        .firstWhere(
          (block) => block.title == section,
          orElse: () => const ProjectBlock(title: ''),
        );
    final cards = CanvasCards.parse(block?.body ?? '');
    if (CanvasExport.pictureCount(cards) == 0) {
      messenger.showSnackBar(
        const SnackBar(content: Text('There are no pictures on this canvas.')),
      );
      return;
    }

    final folder = await getDirectoryPath(
      confirmButtonText: 'Save the pictures here',
    );
    if (folder == null) return;

    final images = await CanvasExport.imagesOf(
      cards,
      // A picture that cannot be fetched is left out rather than written as
      // an empty file, which would look like an export that worked.
      bytesFor: (reference) async {
        final file = await state.attachmentFor(reference);
        return file?.readAsBytes();
      },
    );

    for (final image in images) {
      await File(
        '$folder${Platform.pathSeparator}${image.name}',
      ).writeAsBytes(image.bytes);
    }

    final missing = CanvasExport.pictureCount(cards) - images.length;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          missing == 0
              ? 'Saved ${images.length} pictures to $folder'
              : 'Saved ${images.length} pictures to $folder. '
                    '$missing could not be fetched.',
        ),
      ),
    );
  }

  void _undo() => context.read<AppState>().undoCanvas(slug, section);

  void _redo() => context.read<AppState>().redoCanvas(slug, section);

  Future<void> _drop(DropDoneDetails details) async {
    setState(() => _dropping = false);
    for (final file in details.files) {
      final bytes = await File(file.path).readAsBytes();
      if (!mounted) return;
      await _addBytes(file.name, bytes);
    }
  }

  Future<void> _addPhoto(BuildContext context, {Offset? at}) async {
    final placement = at ?? _canvas.currentState?.sceneAtViewportCentre();
    final files = await openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Images',
          extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'],
        ),
      ],
    );
    if (files.isEmpty) return;

    // Several at once, because a moodboard is not built one picture at a time.
    for (final file in files) {
      await _addBytes(file.name, await file.readAsBytes(), at: placement);
    }
  }

  Future<void> _addNote(BuildContext context) async {
    final state = context.read<AppState>();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => const _NoteDialog(),
    );
    if (text == null || text.trim().isEmpty) return;
    await state.addCanvasCard(slug, section, text.trim());
  }

  void _openLinkedNote(String fileSlug, String title) {
    final state = context.read<AppState>();
    for (final project in state.projects) {
      if (project.fileSlug != fileSlug) continue;
      final index = project.items.indexWhere((item) => item.text == title);
      if (index < 0) continue;
      state.revealItem(project.slug, index);
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ChecklistView(slug: project.slug),
      ));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('This linked note is unavailable.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<AppState>();
    final project = state.projectBySlug(slug);
    final tight = MediaQuery.sizeOf(context).width < 560;

    final block = project?.blocks.firstWhere(
      (block) => block.title == section,
      orElse: () => const ProjectBlock(title: ''),
    );

    if (project == null || block == null || block.title.isEmpty) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('This canvas is no longer here.')),
      );
    }

    final cards = CanvasCards.parse(block.body);
    final spots = CanvasPlacement.place(
      cards,
      state.layoutFor(slug).spotsFor(section),
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): _paste,
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true): _paste,
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undo,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _undo,
        const SingleActivator(
          LogicalKeyboardKey.keyZ,
          control: true,
          shift: true,
        ): _redo,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
            _redo,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): _redo,
      },
      child: Focus(
        autofocus: false,
        child: Scaffold(
          appBar: AppBar(
            title: Text(section),
            // Five buttons and a name do not share one row on a phone: the
            // name was down to three letters and an ellipsis. Undo and redo
            // stay out, since they are reached often and mean nothing in a
            // menu; the three that add things fold into one.
            titleSpacing: tight ? 0 : null,
            actions: [
              if (!tight) ...[
                IconButton(
                  tooltip: 'Add photos',
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  onPressed: () => _addPhoto(context),
                ),
                IconButton(
                  tooltip: 'Add a note',
                  icon: const Icon(Icons.note_add_outlined),
                  onPressed: () => _addNote(context),
                ),
                IconButton(
                  tooltip: 'Paste',
                  icon: const Icon(Icons.content_paste),
                  onPressed: _paste,
                ),
              ] else
                PopupMenuButton<String>(
                  tooltip: 'Add to this canvas',
                  icon: const Icon(Icons.add),
                  onSelected: (choice) {
                    switch (choice) {
                      case 'photo':
                        _addPhoto(context);
                      case 'note':
                        _addNote(context);
                      case 'paste':
                        _paste();
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'photo', child: Text('Add photos')),
                    PopupMenuItem(value: 'note', child: Text('Add a note')),
                    PopupMenuItem(value: 'paste', child: Text('Paste')),
                  ],
                ),
              IconButton(
                tooltip: 'Undo',
                visualDensity: tight ? VisualDensity.compact : null,
                icon: const Icon(Icons.undo),
                onPressed: state.canUndoCanvas(slug, section) ? _undo : null,
              ),
              IconButton(
                tooltip: 'Redo',
                visualDensity: tight ? VisualDensity.compact : null,
                icon: const Icon(Icons.redo),
                onPressed: state.canRedoCanvas(slug, section) ? _redo : null,
              ),
              // Saving a file somewhere you choose is a desktop idea. A phone
              // has no folder to put thirty pictures in that means anything
              // to the person choosing it, so it is not offered there.
              if (CanvasExport.canSaveFiles)
                PopupMenuButton<String>(
                  tooltip: 'Export',
                  icon: const Icon(Icons.ios_share),
                  onSelected: (choice) {
                    if (choice == 'pdf') _exportPdf();
                    if (choice == 'images') _exportImages();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'pdf',
                      child: Text('Save the board as a PDF'),
                    ),
                    PopupMenuItem(
                      value: 'images',
                      child: Text('Save all the pictures'),
                    ),
                  ],
                ),
              const SizedBox(width: 4),
            ],
          ),
          body: RepaintBoundary(
            key: _board,
            child: DropTarget(
              onDragEntered: (_) => setState(() => _dropping = true),
              onDragExited: (_) => setState(() => _dropping = false),
              onDragDone: _drop,
              child: Container(
                foregroundDecoration: _dropping
                    ? BoxDecoration(
                        border: Border.all(
                          color: theme.colorScheme.primary,
                          width: 3,
                        ),
                      )
                    : null,
                child: Stack(
                  children: [
                Positioned.fill(child: CanvasView(
                        key: _canvas,
                        autofocus: true,
                        slug: slug,
                        section: section,
                        cards: cards,
                        spots: spots,
                        settings: state.canvasSettings(slug, section),
                        onSettingsChanged: (settings) => context
                            .read<AppState>()
                            .setCanvasSettings(slug, section, settings),
                        onChanged: (moved) => context
                            .read<AppState>()
                            .setCanvasSpots(slug, section, moved),
                        onRemoveCard: (index) => context
                            .read<AppState>()
                            .removeCanvasCard(slug, section, index),
                        onDuplicateCard: (index) => context
                            .read<AppState>()
                            .duplicateCanvasCard(slug, section, index),
                        onEditCard: (index, markdown) => context
                            .read<AppState>()
                            .setCanvasCard(slug, section, index, markdown),
                        shapes: state.canvasDrawing(slug, section),
                        onDrawShape: (shape) => context
                            .read<AppState>()
                            .addCanvasShape(slug, section, shape),
                        onEraseShapes: (indices) => context
                            .read<AppState>()
                            .removeCanvasShapes(slug, section, indices),
                        onEditShape: (index, shape) => context
                            .read<AppState>()
                            .setCanvasShape(slug, section, index, shape),
                        onPlaceCard: (markdown, spot) =>
                            context.read<AppState>().placeCanvasCard(
                              slug,
                              section,
                              markdown: markdown,
                              spot: spot,
                              behind: spot.isFrame,
                            ),
                        onAddImage: (at) => _addPhoto(context, at: at),
                        onOpenLinkedNote: _openLinkedNote,
                      )),
                for (final position in _pendingPositions)
                  Positioned(
                    left: (_canvas.currentState?.viewportForScene(position).dx ??
                            MediaQuery.sizeOf(context).width / 2) - 130,
                    top: (_canvas.currentState?.viewportForScene(position).dy ??
                            MediaQuery.sizeOf(context).height / 2) - 100,
                    child: IgnorePointer(child: Card(
                      child: SizedBox(width: 260, height: 200,
                        child: Column(mainAxisAlignment: MainAxisAlignment.center,
                          children: [const CircularProgressIndicator(),
                            const SizedBox(height: 14),
                            Text(_pendingImages == 1 ? 'Adding image…' :
                                'Adding $_pendingImages images…')]),
                      ),
                    )),
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

/// Asks for a note to put on the canvas.
class _NoteDialog extends StatefulWidget {
  const _NoteDialog();

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add a note'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 2,
        maxLines: 8,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(hintText: 'Markdown is fine'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Add'),
        ),
      ],
    );
  }
}
