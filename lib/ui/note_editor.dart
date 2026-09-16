import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:provider/provider.dart';

import '../markdown/note_blocks.dart';
import '../markdown/project_links.dart';
import '../state/app_state.dart';
import 'note_blocks_editor.dart';
import 'project_picker.dart';

/// Edits one item's notes in a single view: headings are drawn as headings,
/// images as pictures, and typing a markdown marker converts the line rather
/// than leaving the marker behind.
class NoteEditor extends StatefulWidget {
  const NoteEditor({
    super.key,
    required this.slug,
    required this.index,
    required this.title,
    required this.initialNotes,
  });

  final String slug;
  final int index;
  final String title;
  final String initialNotes;

  static Future<void> open(
    BuildContext context, {
    required String slug,
    required int index,
    required String title,
    required String initialNotes,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NoteEditor(
          slug: slug,
          index: index,
          title: title,
          initialNotes: initialNotes,
        ),
      ),
    );
  }

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  final _editor = GlobalKey<NoteBlocksEditorState>();

  late String _markdown = widget.initialNotes;
  bool _busy = false;
  bool _dropping = false;

  /// Writes the note. Called by Save and by leaving the screen, so a note is
  /// never lost to pressing back.
  Future<void> _persist() async {
    final state = context.read<AppState>();
    // Rewrite any wikilinks that survived into portable markdown, so the file
    // stays readable on GitHub.
    final notes = ProjectLinks.normalize(_markdown, state.projects);

    if (notes.trim() == widget.initialNotes.trim()) return;
    await state.setItemNotes(widget.slug, widget.index, notes);
  }

  Future<void> _saveAndClose() async {
    await _persist();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _linkToProject() async {
    final snippet = await _pickLink();
    if (snippet != null) _editor.currentState?.insertInline(snippet);
  }

  /// Shared by the toolbar button and the `[[` shortcut.
  Future<String?> _pickLink() async {
    final project = await ProjectPicker.show(context, excludeSlug: widget.slug);
    if (project == null || !mounted) return null;
    return ProjectLinks.linkTo(project);
  }

  Future<void> _pickImage() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Images',
          extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp'],
        ),
      ],
    );
    if (file == null || !mounted) return;
    await _upload(file.name, await file.readAsBytes());
  }

  /// Pastes an image when the clipboard holds one, and lets the focused block
  /// handle the paste itself otherwise.
  Future<void> _paste() async {
    final image = await Pasteboard.image;
    if (!mounted) return;

    if (image != null && image.isNotEmpty) {
      final stamp = DateTime.now().toUtc().toIso8601String().split('.').first;
      await _upload('pasted-${stamp.replaceAll(RegExp('[:-]'), '')}.png', image);
      return;
    }

    final text = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final value = text?.text;
    if (value != null && value.isNotEmpty) {
      _editor.currentState?.insertInline(value);
    }
  }

  Future<void> _onDrop(DropDoneDetails details) async {
    for (final file in details.files) {
      if (!mounted) return;
      await _upload(file.name, await file.readAsBytes());
    }
  }

  Future<void> _upload(String fileName, List<int> bytes) async {
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
    if (block != null) _editor.currentState?.insertBlock(block);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      // Back — the app bar arrow, or Android's system back — saves rather
      // than discarding, which is what writing a note then leaving implies.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _saveAndClose();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: 'Link to a project',
              icon: const Icon(Icons.link),
              onPressed: _linkToProject,
            ),
            IconButton(
              tooltip: 'Attach image',
              icon: const Icon(Icons.image_outlined),
              onPressed: _busy ? null : _pickImage,
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton(
                onPressed: _saveAndClose,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_busy) const LinearProgressIndicator(),
            Expanded(child: _buildBody(theme)),
            _Hint(theme: theme),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final editor = CallbackShortcuts(
      bindings: {
        // Replaces the default paste so an image on the clipboard can be
        // uploaded instead of silently doing nothing.
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): _paste,
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true): _paste,
      },
      child: NoteBlocksEditor(
        key: _editor,
        initialMarkdown: widget.initialNotes,
        onChanged: (markdown) => _markdown = markdown,
        onRequestLink: _pickLink,
        onOpenProject: (slug) async {
          // Leave the note before switching, so the editor is not left
          // pointing at an item in another project — saving on the way out,
          // as leaving by any other route does.
          await _persist();
          if (!mounted) return;
          context.read<AppState>().select(slug);
          Navigator.of(context).pop();
        },
      ),
    );

    return DropTarget(
      onDragEntered: (_) => setState(() => _dropping = true),
      onDragExited: (_) => setState(() => _dropping = false),
      onDragDone: (details) {
        setState(() => _dropping = false);
        _onDrop(details);
      },
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _dropping ? theme.colorScheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: editor,
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Type "# " for a heading, "- " for a bullet · [[ links a project · '
            'paste or drop an image · back saves',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
