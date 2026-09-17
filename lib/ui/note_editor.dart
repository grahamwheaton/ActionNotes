import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:provider/provider.dart';

import '../markdown/note_blocks.dart';
import '../markdown/project_links.dart';
import '../state/app_state.dart';
import 'home_shell.dart';
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
    this.onClose,
  });

  final String slug;
  final int index;
  final String title;
  final String initialNotes;

  /// Set when the editor is living in the desktop detail pane rather than on
  /// its own route: there is nothing to pop, so closing is the pane's to do.
  final VoidCallback? onClose;

  /// Opens the note, beside the sidebar on a wide window and as its own
  /// screen on a narrow one.
  ///
  /// Every caller goes through here, so where the editor appears is decided
  /// in one place rather than at each row and menu item.
  static Future<void> open(
    BuildContext context, {
    required String slug,
    required int index,
    required String title,
    required String initialNotes,
  }) async {
    if (MediaQuery.sizeOf(context).width >= HomeShell.sidebarBreakpoint) {
      context.read<AppState>().showNote(slug, index);
      return;
    }

    await Navigator.of(context).push(
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

  /// In the pane, edits settle and save as they go. A route is left by
  /// popping, which saves on the way out; a pane can be replaced by anything
  /// that changes what the detail side shows, so there is no single moment to
  /// hang the write on.
  Timer? _autosave;

  bool get _inPane => widget.onClose != null;

  /// Held so the note can still be written after this widget is gone, which
  /// is the one moment a pane cannot reach for its context.
  AppState? _state;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _state = context.read<AppState>();
  }

  @override
  void dispose() {
    _autosave?.cancel();
    // A pane is taken away by whatever changes the detail side — choosing
    // another project, the item being deleted — and none of those routes
    // through Save or back. Write on the way out so nothing typed is lost.
    if (_inPane) _persistAfterFrame();
    super.dispose();
  }

  /// Writes the note once the frame this teardown belongs to is over.
  ///
  /// Not immediately: saving notifies listeners, and doing that part way
  /// through a build is exactly the error it sounds like.
  void _persistAfterFrame() {
    final state = _state;
    if (state == null) return;

    final notes = ProjectLinks.normalize(_markdown, state.projects);
    if (notes.trim() == widget.initialNotes.trim()) return;

    final slug = widget.slug;
    final index = widget.index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      state.setItemNotes(slug, index, notes);
    });
  }

  void _scheduleAutosave() {
    if (!_inPane) return;
    _autosave?.cancel();
    _autosave = Timer(const Duration(seconds: 1), () {
      if (mounted) _persist();
    });
  }

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
    _autosave?.cancel();
    await _persist();
    if (!mounted) return;

    final close = widget.onClose;
    if (close != null) {
      close();
    } else {
      Navigator.of(context).pop();
    }
  }

  void _undo() => setState(() => _editor.currentState?.undo());

  void _redo() => setState(() => _editor.currentState?.redo());

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
          // In the pane there is no route to pop, so the arrow has to be put
          // there rather than left to the route to supply.
          // A BackButton rather than any arrow, so it reads and behaves as
          // the one a route would have supplied.
          leading: _inPane ? BackButton(onPressed: _saveAndClose) : null,
          // A task title is a sentence more often than a label, so give it
          // room to wrap instead of cutting it off mid-word.
          toolbarHeight: 78,
          title: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              widget.title,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'Undo',
              icon: const Icon(Icons.undo),
              onPressed: _editor.currentState?.canUndo ?? false
                  ? () => setState(() => _editor.currentState?.undo())
                  : null,
            ),
            IconButton(
              tooltip: 'Redo',
              icon: const Icon(Icons.redo),
              onPressed: _editor.currentState?.canRedo ?? false
                  ? () => setState(() => _editor.currentState?.redo())
                  : null,
            ),
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
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undo,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _undo,
        const SingleActivator(
          LogicalKeyboardKey.keyZ,
          control: true,
          shift: true,
        ): _redo,
        const SingleActivator(
          LogicalKeyboardKey.keyZ,
          meta: true,
          shift: true,
        ): _redo,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): _redo,
      },
      child: NoteBlocksEditor(
        key: _editor,
        initialMarkdown: widget.initialNotes,
        onChanged: (markdown) {
          _markdown = markdown;
          _scheduleAutosave();
          // Keeps the undo and redo buttons in step with the history.
          if (mounted) setState(() {});
        },
        onRequestLink: _pickLink,
        onOpenProject: (slug) async {
          // Leave the note before switching, so the editor is not left
          // pointing at an item in another project — saving on the way out,
          // as leaving by any other route does.
          _autosave?.cancel();
          await _persist();
          if (!mounted) return;

          // Selecting another project closes the pane by itself; a route has
          // to be popped.
          context.read<AppState>().select(slug);
          if (!_inPane && mounted) Navigator.of(context).pop();
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
        // Barely any horizontal inset: the block gutter already indents the
        // text, and stacking margins on top of it pushed notes well clear of
        // the edge on a phone.
        margin: const EdgeInsets.fromLTRB(2, 4, 2, 0),
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
            'Type "# " heading · "- " bullet · "- [ ] " checkbox · Tab nests · '
            '[[ links a project · Ctrl+Z undoes · back saves',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
