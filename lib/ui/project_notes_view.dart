import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../markdown/note_conversation.dart';
import '../markdown/project_links.dart';
import '../models/project.dart';
import '../state/app_state.dart';
import 'conversation_view.dart';
import 'note_blocks_editor.dart';
import 'note_images.dart';

/// A project that is a document rather than a checklist.
///
/// The file is the same either way — a notes project is one with no checklist
/// lines — so this is a second view over `project.notes`, not a second format.
/// Turning a project into notes and back leaves the file as it was, and a
/// project with both items and a body keeps its items even while they are not
/// on screen.
class ProjectNotesView extends StatefulWidget {
  const ProjectNotesView({super.key, required this.slug});

  final String slug;

  @override
  State<ProjectNotesView> createState() => _ProjectNotesViewState();
}

class _ProjectNotesViewState extends State<ProjectNotesView> {
  final _editor = GlobalKey<NoteBlocksEditorState>();
  final _images = GlobalKey<NoteImageTargetState>();

  /// What is in the editor now, written after a pause rather than per
  /// keystroke — the same bargain the inline notes make.
  String? _pending;
  Timer? _autosave;

  /// Held so the last edit can still be written while this view goes away,
  /// when the context can no longer be read.
  late AppState _state;

  /// The body as it stood when the editor was built. The editor owns its
  /// blocks from then on, so rebuilding it from the project on every frame
  /// would fight whoever is typing.
  late String _initial = _state.projectBySlug(widget.slug)?.notes ?? '';

  late bool _asConversation = NoteConversation.looksConversational(_initial);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _state = context.read<AppState>();
    _state.registerEditorSave(_persist);
  }

  @override
  void dispose() {
    _state.unregisterEditorSave(_persist);
    _autosave?.cancel();
    _persist();
    super.dispose();
  }

  void _changed(String markdown) {
    _pending = markdown;
    _autosave?.cancel();
    _autosave = Timer(const Duration(milliseconds: 700), _persist);
  }

  Future<void> _persist() async {
    _autosave?.cancel();
    final markdown = _pending;
    _pending = null;
    if (markdown == null) return;
    await _state.setNotes(
      widget.slug,
      ProjectLinks.normalize(markdown, _state.projects),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _asConversation
              ? SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: ConversationView(
                    markdown: _pending ?? _initial,
                    onSend: (markdown) {
                      setState(() => _initial = markdown);
                      _pending = markdown;
                      _persist();
                    },
                    onOpenProject: (slug) =>
                        context.read<AppState>().select(slug),
                  ),
                )
              : NoteImageTarget(
                  key: _images,
                  slug: widget.slug,
                  editor: _editor,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: NoteBlocksEditor(
                      key: _editor,
                      autofocus: true,
                      initialMarkdown: _initial,
                      onChanged: _changed,
                      onPaste: () async => _images.currentState?.paste(),
                      onRequestImage: () async =>
                          _images.currentState?.pickImage(),
                      onOpenProject: (slug) =>
                          context.read<AppState>().select(slug),
                    ),
                  ),
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Row(
              children: [
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: theme.textTheme.labelSmall,
                  ),
                  icon: Icon(
                    _asConversation ? Icons.edit_note : Icons.forum_outlined,
                    size: 16,
                  ),
                  label: Text(
                    _asConversation ? 'Edit as markdown' : 'Conversation',
                  ),
                  onPressed: () {
                    // Leaving either view writes what is in hand, so switching
                    // cannot lose a message.
                    _autosave?.cancel();
                    _persist();
                    setState(() {
                      _initial =
                          _state.projectBySlug(widget.slug)?.notes ?? _initial;
                      _asConversation = !_asConversation;
                    });
                  },
                ),
                const Spacer(),
                if (!_asConversation)
                  IconButton(
                    tooltip: 'Attach image',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.image_outlined, size: 20),
                    onPressed: () => _images.currentState?.pickImage(),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// True when this project should open as a document.
bool opensAsNotes(Project project) => project.mode == ProjectMode.notes;
