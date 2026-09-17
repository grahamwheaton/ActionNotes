import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../markdown/project_links.dart';
import '../models/checklist_item.dart';
import '../models/project.dart';
import '../state/app_state.dart';
import 'context_menu.dart';
import 'note_blocks_editor.dart';
import 'note_editor.dart';
import 'note_view.dart';
import 'tag_pill.dart';
import 'text_prompt.dart';

/// One project's checklist: open items first, then a collapsible Completed
/// group at the bottom, mirroring Microsoft To Do's shape.
class ChecklistView extends StatefulWidget {
  const ChecklistView({super.key, required this.slug, this.showAppBar = true});

  final String slug;

  /// False when embedded in the desktop two-pane layout, which supplies its
  /// own header.
  final bool showAppBar;

  @override
  State<ChecklistView> createState() => _ChecklistViewState();
}

class _ChecklistViewState extends State<ChecklistView> {
  final _newItemController = TextEditingController();
  final _newItemFocus = FocusNode();
  bool _completedExpanded = true;

  /// Items whose notes are open in place, keyed by the item's text.
  ///
  /// Not by index: a new item goes to the top of the list and a deletion
  /// closes a gap, so an index stops meaning the same row the moment the list
  /// changes. Keeping the text means a row that moves keeps its open note.
  final Set<String> _expandedNotes = {};

  void _toggleNotes(int index, String itemText) {
    // Closing a note is a good moment to be sure it is written, rather than
    // trusting the pause timer to have fired first.
    if (_expandedNotes.contains(itemText)) _flushNotes(itemText);
    setState(() {
      if (!_expandedNotes.remove(itemText)) _expandedNotes.add(itemText);
    });
  }

  /// Notes edited in place but not yet written, keyed by the item's text.
  ///
  /// Writing on every keystroke would push a commit per letter, so an edit
  /// settles for a moment first — the same bargain the note editor's history
  /// makes with undo.
  ///
  /// The key is the item's text rather than its index for the same reason as
  /// above, and here it matters more than tidiness: an index captured when
  /// the edit started could point at a different item by the time the timer
  /// fires, and the note would be written over that item's notes instead.
  /// Adding an item is enough to cause it, since a new item is prepended.
  ///
  /// Two items in one project with identical text share a buffer. That is
  /// worth the trade: it is unusual, and the failure is two rows agreeing
  /// rather than a note landing on an unrelated item.
  final Map<String, String> _pendingNotes = {};
  final Map<String, Timer> _noteTimers = {};

  void _notesChanged(String itemText, String markdown) {
    _pendingNotes[itemText] = markdown;
    _noteTimers[itemText]?.cancel();
    _noteTimers[itemText] =
        Timer(const Duration(milliseconds: 700), () => _flushNotes(itemText));
  }

  void _flushNotes(String itemText) {
    _noteTimers.remove(itemText)?.cancel();
    final markdown = _pendingNotes.remove(itemText);
    if (markdown == null) return;

    // Find where the item is now, rather than where it was when the edit
    // started. If it has gone — deleted, or its text edited — the note is
    // dropped, which is better than writing it onto whichever item has since
    // taken that position.
    final project = _state.projectBySlug(widget.slug);
    if (project == null) return;

    final index = project.items.indexWhere((item) => item.text == itemText);
    if (index < 0) return;

    // Wikilinks become portable markdown on the way out, as they do when the
    // note is saved from its own screen.
    _state.setItemNotes(
      widget.slug,
      index,
      ProjectLinks.normalize(markdown, _state.projects),
    );
  }

  /// Held so a note still in hand can be written while this view is going
  /// away, when reading the state off the context is no longer allowed.
  late AppState _state;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _state = context.read<AppState>();
  }

  @override
  void dispose() {
    for (final itemText in _pendingNotes.keys.toList()) {
      _flushNotes(itemText);
    }
    _newItemController.dispose();
    _newItemFocus.dispose();
    super.dispose();
  }

  void _addItem() {
    final text = _newItemController.text.trim();
    if (text.isEmpty) return;

    context.read<AppState>().addItem(widget.slug, text);
    _newItemController.clear();
    // Keep focus so a list can be typed out without reaching for the field.
    _newItemFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final project = context.watch<AppState>().projectBySlug(widget.slug);

    // The project can vanish underneath us if it is deleted elsewhere.
    if (project == null) {
      return Scaffold(
        appBar: widget.showAppBar ? AppBar() : null,
        body: const Center(child: Text('This project is no longer here.')),
      );
    }

    // Indices are into project.items, so edits address the right line even
    // though the view is grouped. Starred items are pinned above the rest of
    // the open ones; each group keeps its own order from the file.
    final starred = <int>[];
    final open = <int>[];
    final done = <int>[];
    for (var i = 0; i < project.items.length; i++) {
      final item = project.items[i];
      if (item.done) {
        done.add(i);
      } else if (item.starred) {
        starred.add(i);
      } else {
        open.add(i);
      }
    }

    return Scaffold(
      appBar: widget.showAppBar
          ? AppBar(
              title: Text(project.title),
              actions: [_ProjectMenu(project: project)],
            )
          : null,
      body: Column(
        children: [
          Expanded(
            child: project.items.isEmpty
                ? const _EmptyChecklist()
                : CustomScrollView(
                    slivers: [
                      // Starred first, each group draggable within itself so a
                      // drag cannot silently unstar or unpin something.
                      if (starred.isNotEmpty)
                        SliverReorderableList(
                          itemCount: starred.length,
                          onReorderItem: (oldIndex, newIndex) => context
                              .read<AppState>()
                              .reorderSlots(
                                widget.slug,
                                starred,
                                oldIndex,
                                newIndex,
                              ),
                          itemBuilder: (context, position) {
                            final index = starred[position];
                            return _ItemTile(
                              key: ValueKey('starred-${widget.slug}-$index'),
                              slug: widget.slug,
                              index: index,
                              item: project.items[index],
                              dragPosition: position,
                              notesExpanded: _expandedNotes.contains(project.items[index].text),
                              onToggleNotes: () =>
                                  _toggleNotes(index, project.items[index].text),
                              onNotesChanged: (notes) =>
                                  _notesChanged(
                                    project.items[index].text,
                                    notes,
                                  ),
                            );
                          },
                        ),
                      SliverReorderableList(
                        itemCount: open.length,
                        onReorderItem: (oldIndex, newIndex) =>
                            context.read<AppState>().reorderSlots(
                                  widget.slug,
                                  open,
                                  oldIndex,
                                  newIndex,
                                ),
                        itemBuilder: (context, position) {
                          final index = open[position];
                          return _ItemTile(
                            key: ValueKey('open-${widget.slug}-$index'),
                            slug: widget.slug,
                            index: index,
                            item: project.items[index],
                            dragPosition: position,
                            notesExpanded: _expandedNotes.contains(project.items[index].text),
                            onToggleNotes: () =>
                                  _toggleNotes(index, project.items[index].text),
                              onNotesChanged: (notes) =>
                                  _notesChanged(
                                    project.items[index].text,
                                    notes,
                                  ),
                          );
                        },
                      ),
                      if (done.isNotEmpty)
                        SliverToBoxAdapter(
                          child: _CompletedHeader(
                            count: done.length,
                            expanded: _completedExpanded,
                            onTap: () => setState(
                              () => _completedExpanded = !_completedExpanded,
                            ),
                          ),
                        ),
                      if (_completedExpanded)
                        SliverList.builder(
                          itemCount: done.length,
                          itemBuilder: (context, position) {
                            final index = done[position];
                            return _ItemTile(
                              key: ValueKey('done-${widget.slug}-$index'),
                              slug: widget.slug,
                              index: index,
                              item: project.items[index],
                              notesExpanded: _expandedNotes.contains(project.items[index].text),
                              onToggleNotes: () =>
                                  _toggleNotes(index, project.items[index].text),
                              onNotesChanged: (notes) =>
                                  _notesChanged(
                                    project.items[index].text,
                                    notes,
                                  ),
                            );
                          },
                        ),
                      const SliverToBoxAdapter(child: SizedBox(height: 8)),
                    ],
                  ),
          ),
          if (project.notes.trim().isNotEmpty) _ProjectNotes(project: project),
          _AddItemBar(
            controller: _newItemController,
            focusNode: _newItemFocus,
            onSubmit: _addItem,
          ),
        ],
      ),
    );
  }
}

class _CompletedHeader extends StatelessWidget {
  const _CompletedHeader({
    required this.count,
    required this.expanded,
    required this.onTap,
  });

  final int count;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Material(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    expanded ? Icons.keyboard_arrow_down : Icons.chevron_right,
                    size: 18,
                  ),
                  const SizedBox(width: 4),
                  Text('Completed', style: theme.textTheme.labelLarge),
                  const SizedBox(width: 8),
                  Text('$count', style: theme.textTheme.labelLarge),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({
    super.key,
    required this.slug,
    required this.index,
    required this.item,
    required this.notesExpanded,
    required this.onToggleNotes,
    required this.onNotesChanged,
    this.dragPosition,
  });

  final String slug;

  /// Index into the project's full item list, so edits hit the right line
  /// even though the view is grouped.
  final int index;
  final ChecklistItem item;

  /// Position within the draggable open items, or null for a completed item.
  final int? dragPosition;

  /// Whether this item's notes are showing under it.
  final bool notesExpanded;
  final VoidCallback onToggleNotes;

  /// Fires as the notes are edited in place, for the view to save.
  final ValueChanged<String> onNotesChanged;

  /// Starred and still open: worth picking out of the list.
  bool get highlighted => item.starred && !item.done;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<AppState>();

    return ItemContextMenu(
      actions: [
        ContextMenuAction(
          label: item.starred ? 'Remove star' : 'Star',
          icon: item.starred ? Icons.star_border : Icons.star,
          onSelected: () => state.toggleStar(slug, index),
        ),
        ContextMenuAction(
          label: item.hasNotes ? 'Edit notes' : 'Add notes',
          icon: Icons.notes_outlined,
          onSelected: () => NoteEditor.open(
            context,
            slug: slug,
            index: index,
            title: item.title,
            initialNotes: item.notes,
          ),
        ),
        ContextMenuAction(
          label: 'Rename',
          icon: Icons.drive_file_rename_outline,
          onSelected: () async {
            final text = await TextPromptDialog.show(
              context,
              title: 'Edit item',
              initialValue: item.text,
            );
            if (text != null) await state.editItem(slug, index, text);
          },
        ),
        ContextMenuAction(
          label: 'Delete',
          icon: Icons.delete_outline,
          destructive: true,
          onSelected: () => state.removeItem(slug, index),
        ),
      ],
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        // A starred row is tinted and outlined in the accent colour, so the
        // ones that matter are findable without reading the stars. A starred
        // item that is done has had its moment, and goes back to looking
        // like the rest.
        decoration: BoxDecoration(
          color: highlighted
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.45)
              : theme.colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: highlighted
                ? theme.colorScheme.primary.withValues(alpha: 0.5)
                : theme.colorScheme.outlineVariant,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Anywhere on the row opens the note. The checkbox, star, notes
            // marker and drag handle sit on top and take their own taps.
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => NoteEditor.open(
                context,
                slug: slug,
                index: index,
                title: item.title,
                initialNotes: item.notes,
              ),
              child: Row(
              children: [
                Checkbox(
                  value: item.done,
                  onChanged: (_) => state.toggleItem(slug, index),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: _ItemTitle(item: item),
                  ),
                ),
                _NotesToggle(
                  expanded: notesExpanded,
                  hasNotes: item.hasNotes,
                  onTap: onToggleNotes,
                ),
                IconButton(
                  tooltip: item.starred ? 'Remove star' : 'Star',
                  icon: Icon(
                    item.starred ? Icons.star : Icons.star_border,
                    size: 20,
                    color: item.starred
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline,
                  ),
                  onPressed: () => state.toggleStar(slug, index),
                ),
                // An explicit handle rather than a long-press drag, because
                // long-press opens the context menu.
                if (dragPosition != null)
                  ReorderableDragStartListener(
                    index: dragPosition!,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8, left: 2),
                      child: Icon(
                        Icons.drag_indicator,
                        size: 18,
                        color: theme.colorScheme.outlineVariant,
                      ),
                    ),
                  ),
              ],
            ),
            ),
            if (notesExpanded)
              Padding(
                // Indented to start under the item's text, not its checkbox.
                padding: const EdgeInsets.fromLTRB(36, 0, 12, 10),
                child: NoteBlocksEditor(
                  // Keyed by the item so that editing one note and opening
                  // another does not hand the second the first one's blocks.
                  // By text, not index: an index is reused by whichever row
                  // moves into it, which would hand the editor's blocks to a
                  // different item's note.
                  key: ValueKey('notes-$slug-${item.text}'),
                  initialMarkdown: item.notes,
                  shrinkWrap: true,
                  onChanged: onNotesChanged,
                  onOpenProject: (slug) =>
                      context.read<AppState>().select(slug),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Opens an item's notes underneath it.
///
/// Sits with the star at the right-hand end of the row, so the controls are
/// together and the item's text is left to be text.
///
/// On every row, whether or not there is a note yet: it used to appear only
/// once an item had notes, which meant the section could not be found until
/// a note had been written some other way — and on a desktop, where clicking
/// the row opens the full editor, there was nothing to suggest notes opened
/// in place at all.
class _NotesToggle extends StatelessWidget {
  const _NotesToggle({
    required this.expanded,
    required this.hasNotes,
    required this.onTap,
  });

  final bool expanded;
  final bool hasNotes;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return IconButton(
      tooltip: switch ((expanded, hasNotes)) {
        (true, _) => 'Hide notes',
        (false, true) => 'Show notes',
        (false, false) => 'Add notes',
      },
      onPressed: onTap,
      icon: Icon(
        switch ((expanded, hasNotes)) {
          (true, _) => Icons.expand_less,
          (false, true) => Icons.notes,
          // An empty row of lines, to say there is nothing there yet.
          (false, false) => Icons.notes_outlined,
        },
        size: 20,
        color: expanded
            ? theme.colorScheme.primary
            : hasNotes
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.outlineVariant,
      ),
    );
  }
}

/// An item's text, with its `[tag]` markers shown as pills rather than
/// brackets. Wrapped so a long title and its tags flow onto another line
/// instead of squeezing each other.
class _ItemTitle extends StatelessWidget {
  const _ItemTitle({required this.item});

  final ChecklistItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyLarge?.copyWith(
      decoration: item.done ? TextDecoration.lineThrough : null,
      color: item.done ? theme.colorScheme.outline : null,
    );

    final tags = item.tags;
    if (tags.isEmpty) return Text(item.text, style: style);

    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // A title made of nothing but tags would otherwise render an empty
        // line above the pills.
        if (item.title.isNotEmpty) Text(item.title, style: style),
        for (final tag in tags) TagPill(tag: tag, faded: item.done),
      ],
    );
  }
}

class _AddItemBar extends StatelessWidget {
  const _AddItemBar({
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(hintText: 'Add an item'),
                onSubmitted: (_) => onSubmit(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: onSubmit,
              icon: const Icon(Icons.add),
              tooltip: 'Add item',
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectNotes extends StatelessWidget {
  const _ProjectNotes({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 160),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SingleChildScrollView(
        child: NoteView(
          markdown: project.notes.trim(),
          onOpenProject: (slug) => context.read<AppState>().select(slug),
        ),
      ),
    );
  }
}

class _ProjectMenu extends StatelessWidget {
  const _ProjectMenu({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();

    return PopupMenuButton<String>(
      onSelected: (value) async {
        switch (value) {
          case 'clear':
            await state.clearCompleted(project.slug);
          case 'notes':
            final notes = await TextPromptDialog.show(
              context,
              title: 'Project notes',
              initialValue: project.notes,
              hintText: 'Markdown, saved under the checklist in the file',
              maxLines: 8,
              minLines: 4,
              allowEmpty: true,
            );
            if (notes != null) await state.setNotes(project.slug, notes);
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'clear', child: Text('Clear completed')),
        PopupMenuItem(value: 'notes', child: Text('Project notes')),
      ],
    );
  }
}

class _EmptyChecklist extends StatelessWidget {
  const _EmptyChecklist();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Text(
        'Nothing here yet — add your first item below.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
