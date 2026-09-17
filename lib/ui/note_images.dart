import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:provider/provider.dart';

import '../markdown/note_blocks.dart';
import '../state/app_state.dart';
import 'note_blocks_editor.dart';

/// Gives a note its images: pasted with Ctrl+V, dropped from the desktop, or
/// picked from disk.
///
/// Wraps an editor rather than living inside one, because both editors need
/// it — the note on its own screen and the note opened inside a checklist
/// row. Pasting a screenshot should not depend on which of the two is open.
class NoteImageTarget extends StatefulWidget {
  const NoteImageTarget({
    super.key,
    required this.slug,
    required this.editor,
    required this.child,
    this.showProgress = true,
  });

  /// Which project's `attachments/` the file goes to.
  final String slug;

  /// The editor an uploaded image is inserted into.
  final GlobalKey<NoteBlocksEditorState> editor;

  final Widget child;

  /// Whether to draw a bar while a file uploads. The full editor has room for
  /// one; a row in a list does not.
  final bool showProgress;

  @override
  State<NoteImageTarget> createState() => NoteImageTargetState();
}

class NoteImageTargetState extends State<NoteImageTarget> {
  bool _busy = false;
  bool _dropping = false;

  bool get busy => _busy;

  /// Pastes an image when the clipboard holds one, and the text otherwise, so
  /// replacing the default paste does not lose the ordinary case.
  Future<void> paste() async {
    final image = await Pasteboard.image;
    if (!mounted) return;

    if (image != null && image.isNotEmpty) {
      final stamp = DateTime.now().toUtc().toIso8601String().split('.').first;
      await upload('pasted-${stamp.replaceAll(RegExp('[:-]'), '')}.png', image);
      return;
    }

    final text = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;

    final value = text?.text;
    if (value != null && value.isNotEmpty) {
      widget.editor.currentState?.insertInline(value);
    }
  }

  Future<void> pickImage() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Images',
          extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp'],
        ),
      ],
    );
    if (file == null || !mounted) return;
    await upload(file.name, await file.readAsBytes());
  }

  Future<void> upload(String fileName, List<int> bytes) async {
    setState(() => _busy = true);

    final reference = await context.read<AppState>().attachImage(
          widget.slug,
          fileName: fileName,
          bytes: bytes,
        );
    if (!mounted) return;
    setState(() => _busy = false);

    // A failed upload already surfaced a message on the state.
    if (reference == null) return;

    // attachImage hands back the markdown; the editor wants the parts.
    final block = NoteBlocks.parse(reference).firstOrNull;
    if (block != null) widget.editor.currentState?.insertBlock(block);
  }

  Future<void> _onDrop(DropDoneDetails details) async {
    for (final file in details.files) {
      if (!mounted) return;
      await upload(file.name, await file.readAsBytes());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return CallbackShortcuts(
      bindings: {
        // Replaces the default paste so an image on the clipboard can be
        // uploaded instead of silently doing nothing.
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): paste,
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true): paste,
      },
      child: DropTarget(
        onDragEntered: (_) => setState(() => _dropping = true),
        onDragExited: (_) => setState(() => _dropping = false),
        onDragDone: (details) {
          setState(() => _dropping = false);
          _onDrop(details);
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_busy && widget.showProgress) const LinearProgressIndicator(),
            Flexible(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _dropping
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: widget.child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
