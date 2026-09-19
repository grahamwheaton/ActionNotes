import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:provider/provider.dart';

import '../markdown/canvas_cards.dart';
import '../markdown/canvas_placement.dart';
import '../models/project.dart';
import '../state/app_state.dart';
import 'canvas_view.dart';

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

  /// Adds one image from bytes already in hand — a paste, or a dropped file.
  Future<void> _addBytes(String name, List<int> bytes) async {
    final state = context.read<AppState>();
    final reference = await state.attachImage(
      slug,
      fileName: name,
      bytes: bytes,
    );
    if (reference == null) return;
    await state.addCanvasCard(slug, section, reference);
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

  Future<void> _drop(DropDoneDetails details) async {
    setState(() => _dropping = false);
    for (final file in details.files) {
      final bytes = await File(file.path).readAsBytes();
      if (!mounted) return;
      await _addBytes(file.name, bytes);
    }
  }

  Future<void> _addPhoto(BuildContext context) async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);

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
      final reference = await state.attachImage(
        slug,
        fileName: file.name,
        bytes: await file.readAsBytes(),
      );
      if (reference == null) {
        messenger.showSnackBar(
          SnackBar(content: Text('Could not add ${file.name}.')),
        );
        return;
      }
      await state.addCanvasCard(slug, section, reference);
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<AppState>();
    final project = state.projectBySlug(slug);

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
      },
      child: Focus(
        autofocus: false,
        child: Scaffold(
          appBar: AppBar(
            title: Text(section),
            actions: [
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
              const SizedBox(width: 4),
            ],
          ),
          body: DropTarget(
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
              child: cards.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'Nothing on this canvas yet.\n'
                          'Add photos from the bar, paste one in, or drop files here.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  : CanvasView(
                      autofocus: true,
                      slug: slug,
                      section: section,
                      cards: cards,
                      spots: spots,
                      onChanged: (moved) => context
                          .read<AppState>()
                          .setCanvasSpots(slug, section, moved),
                      onRemoveCard: (index) => context
                          .read<AppState>()
                          .removeCanvasCard(slug, section, index),
                      onDuplicateCard: (index) => context
                          .read<AppState>()
                          .duplicateCanvasCard(slug, section, index),
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
