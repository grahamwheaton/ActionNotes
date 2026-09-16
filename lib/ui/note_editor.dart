import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'note_view.dart';

/// Edits one item's notes: markdown on the left tab, rendered preview on the
/// right, and a button that uploads an image and inserts a reference to it.
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
  bool _uploading = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await context.read<AppState>().setItemNotes(
          widget.slug,
          widget.index,
          _controller.text,
        );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _attachImage() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Images',
          extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp'],
        ),
      ],
    );
    if (file == null || !mounted) return;

    setState(() => _uploading = true);
    final bytes = await file.readAsBytes();
    if (!mounted) return;

    final reference = await context.read<AppState>().attachImage(
          widget.slug,
          fileName: file.name,
          bytes: bytes,
        );
    if (!mounted) return;
    setState(() => _uploading = false);

    // A failed upload already surfaced a message on the state.
    if (reference == null) return;
    _insert(reference);
  }

  /// Puts [snippet] at the caret, on its own line.
  void _insert(String snippet) {
    final text = _controller.text;
    final selection = _controller.selection;
    final at = selection.isValid ? selection.start : text.length;

    final before = text.substring(0, at);
    final after = text.substring(selection.isValid ? selection.end : at);
    final prefix = before.isEmpty || before.endsWith('\n') ? '' : '\n';

    final inserted = '$prefix$snippet\n';
    _controller.value = TextEditingValue(
      text: '$before$inserted$after',
      selection: TextSelection.collapsed(offset: before.length + inserted.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: _preview ? 'Edit' : 'Preview',
            icon: Icon(_preview ? Icons.edit_outlined : Icons.visibility_outlined),
            onPressed: () => setState(() => _preview = !_preview),
          ),
          IconButton(
            tooltip: 'Attach image',
            icon: const Icon(Icons.image_outlined),
            onPressed: _uploading ? null : _attachImage,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(onPressed: _save, child: const Text('Save')),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_uploading) const LinearProgressIndicator(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _preview
                  ? SingleChildScrollView(
                      child: _controller.text.trim().isEmpty
                          ? Text(
                              'Nothing to preview yet.',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            )
                          : NoteView(markdown: _controller.text),
                    )
                  : TextField(
                      controller: _controller,
                      autofocus: true,
                      expands: true,
                      maxLines: null,
                      minLines: null,
                      textAlignVertical: TextAlignVertical.top,
                      style: theme.textTheme.bodyMedium,
                      decoration: const InputDecoration(
                        hintText: 'Markdown notes. Attach an image with the '
                            'toolbar button, or write any markdown you like.',
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
