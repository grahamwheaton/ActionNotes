import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:provider/provider.dart';

import '../markdown/project_links.dart';
import '../state/app_state.dart';
import 'note_view.dart';
import 'project_picker.dart';

/// Edits one item's notes.
///
/// Aims at the parts of Obsidian that matter for a task note: markdown with
/// inline images you can paste or drop straight in, and links to other
/// projects that resolve both here and on github.com.
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
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialNotes);
  bool _preview = false;
  bool _busy = false;
  bool _dropping = false;

  /// Guards against the `[[` handler firing repeatedly while the picker is up.
  bool _pickerOpen = false;
  String _lastText = '';

  @override
  void initState() {
    super.initState();
    _lastText = _controller.text;
    _controller.addListener(_watchForWikilink);
  }

  @override
  void dispose() {
    _controller.removeListener(_watchForWikilink);
    _controller.dispose();
    super.dispose();
  }

  /// Typing `[[`, as in Obsidian, opens the project picker.
  void _watchForWikilink() {
    final text = _controller.text;
    if (text == _lastText) return;

    final grew = text.length > _lastText.length;
    _lastText = text;
    if (!grew || _pickerOpen || _preview) return;

    final caret = _controller.selection.baseOffset;
    if (caret < 2) return;
    if (text.substring(caret - 2, caret) != '[[') return;

    _pickerOpen = true;
    // Let the field settle before putting a dialog over it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _completeWikilink());
  }

  Future<void> _completeWikilink() async {
    final project = await ProjectPicker.show(context, excludeSlug: widget.slug);
    _pickerOpen = false;
    if (!mounted) return;

    final caret = _controller.selection.baseOffset;
    if (caret < 2) return;

    // Replace the `[[` that triggered this, whether or not one was chosen.
    final before = _controller.text.substring(0, caret - 2);
    final after = _controller.text.substring(caret);
    final insert = project == null ? '' : ProjectLinks.linkTo(project);

    _controller.value = TextEditingValue(
      text: '$before$insert$after',
      selection: TextSelection.collapsed(offset: before.length + insert.length),
    );
    _lastText = _controller.text;
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    // Rewrite any wikilinks that survived into portable markdown, so the file
    // stays readable on GitHub.
    final notes = ProjectLinks.normalize(_controller.text, state.projects);

    await state.setItemNotes(widget.slug, widget.index, notes);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _linkToProject() async {
    final project = await ProjectPicker.show(context, excludeSlug: widget.slug);
    if (project == null || !mounted) return;
    _insert(ProjectLinks.linkTo(project), inline: true);
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

  /// Pastes an image when the clipboard holds one, and text otherwise, so
  /// Ctrl+V does the expected thing either way.
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
    if (value != null && value.isNotEmpty) _insert(value, inline: true);
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
    if (reference != null) _insert(reference);
  }

  /// Puts [snippet] at the caret. Block content goes on its own line;
  /// [inline] content is dropped in where the caret sits.
  void _insert(String snippet, {bool inline = false}) {
    final text = _controller.text;
    final selection = _controller.selection;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : start;

    final before = text.substring(0, start);
    final after = text.substring(end);

    final needsBreak =
        !inline && before.isNotEmpty && !before.endsWith('\n');
    final inserted = inline ? snippet : '${needsBreak ? '\n' : ''}$snippet\n';

    _controller.value = TextEditingValue(
      text: '$before$inserted$after',
      selection:
          TextSelection.collapsed(offset: before.length + inserted.length),
    );
    _lastText = _controller.text;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Link to a project',
            icon: const Icon(Icons.link),
            onPressed: _preview ? null : _linkToProject,
          ),
          IconButton(
            tooltip: 'Attach image',
            icon: const Icon(Icons.image_outlined),
            onPressed: _busy || _preview ? null : _pickImage,
          ),
          IconButton(
            tooltip: _preview ? 'Edit' : 'Preview',
            icon:
                Icon(_preview ? Icons.edit_outlined : Icons.visibility_outlined),
            onPressed: () => setState(() => _preview = !_preview),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(onPressed: _save, child: const Text('Save')),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _preview ? _buildPreview(theme) : _buildEditor(theme),
            ),
          ),
          _Hint(preview: _preview),
        ],
      ),
    );
  }

  Widget _buildPreview(ThemeData theme) {
    return SingleChildScrollView(
      child: _controller.text.trim().isEmpty
          ? Text(
              'Nothing to preview yet.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : NoteView(
              markdown: _controller.text,
              onOpenProject: (slug) {
                // Leave the note before switching, so the editor is not left
                // pointing at an item in another project.
                context.read<AppState>().select(slug);
                Navigator.of(context).pop();
              },
            ),
    );
  }

  Widget _buildEditor(ThemeData theme) {
    final field = CallbackShortcuts(
      bindings: {
        // Replaces the default paste so an image on the clipboard can be
        // uploaded instead of silently doing nothing.
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): _paste,
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true): _paste,
      },
      child: TextField(
        controller: _controller,
        autofocus: true,
        expands: true,
        maxLines: null,
        minLines: null,
        textAlignVertical: TextAlignVertical.top,
        style: theme.textTheme.bodyMedium,
        decoration: const InputDecoration(
          hintText: 'Markdown notes. Type [[ to link a project, paste or drop '
              'an image to attach it.',
        ),
      ),
    );

    return DropTarget(
      onDragEntered: (_) => setState(() => _dropping = true),
      onDragExited: (_) => setState(() => _dropping = false),
      onDragDone: (details) {
        setState(() => _dropping = false);
        _onDrop(details);
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _dropping
                ? theme.colorScheme.primary
                : Colors.transparent,
            width: 2,
          ),
        ),
        child: field,
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.preview});

  final bool preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            preview
                ? 'Tap a project link to open it.'
                : 'Type [[ to link a project · paste or drop an image to attach it',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
