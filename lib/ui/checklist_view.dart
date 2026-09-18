import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../markdown/note_conversation.dart';
import '../markdown/project_links.dart';
import '../models/checklist_item.dart';
import '../models/project.dart';
import '../state/app_state.dart';
import 'context_menu.dart';
import 'conversation_view.dart';
import 'note_blocks_editor.dart';
import 'note_editor.dart';
import 'note_images.dart';
import 'note_view.dart';
import 'project_picker.dart';
import 'tag_pill.dart';
import 'text_prompt.dart';
import 'touch_input.dart';

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
  final _scroll = ScrollController();
  bool _completedExpanded = true;

  /// The item a search asked for, marked for a moment so the eye can find it.
  /// By text, for the same reason the note buffers are: an index stops
  /// meaning the same row as soon as the list changes.
  String? _flashing;
  Timer? _flashTimer;

  /// Items whose notes are open in place, keyed by the item's text.
  ///
  /// Not by index: a new item goes to the top of the list and a deletion
  /// closes a gap, so an index stops meaning the same row the moment the list
  /// changes. Keeping the text means a row that moves keeps its open note.
  final Set<String> _expandedNotes = {};

  void _toggleNotes(int index, String itemText) {
    // Alt makes it a decision about the whole project, the way alt-clicking a
    // disclosure in a file tree does.
    if (HardwareKeyboard.instance.isAltPressed) {
      _toggleAllNotes(opening: !_expandedNotes.contains(itemText));
      return;
    }

    // Closing a note is a good moment to be sure it is written, rather than
    // trusting the pause timer to have fired first.
    if (_expandedNotes.contains(itemText)) _flushNotes(itemText);
    setState(() {
      if (!_expandedNotes.remove(itemText)) _expandedNotes.add(itemText);
    });
  }

  /// Opens or closes every item's notes at once.
  ///
  /// [opening] follows the row that was alt-clicked, so alt-clicking a closed
  /// note opens them all and alt-clicking an open one closes them all —
  /// rather than each row flipping to its own opposite, which would leave the
  /// list half open.
  void _toggleAllNotes({required bool opening}) {
    final project = _state.projectBySlug(widget.slug);
    if (project == null) return;

    // Everything on the way out gets written, as closing one note does.
    if (!opening) {
      for (final itemText in _pendingNotes.keys.toList()) {
        _flushNotes(itemText);
      }
    }

    setState(() {
      _expandedNotes.clear();
      if (opening) {
        _expandedNotes.addAll(project.items.map((item) => item.text));
      }
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
    _noteTimers[itemText] = Timer(
      const Duration(milliseconds: 700),
      () => _flushNotes(itemText),
    );
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
    _flashTimer?.cancel();
    _scroll.dispose();
    _newItemController.dispose();
    _newItemFocus.dispose();
    super.dispose();
  }

  /// Scrolls to the item a search picked and marks it.
  ///
  /// The offset is estimated from the row's place in the view rather than
  /// measured: the rows are built lazily, so the one being looked for usually
  /// does not exist yet to be measured. Landing near it and marking it is
  /// what the search was for.
  void _revealItem(Project project, List<int> viewOrder, int index) {
    final position = viewOrder.indexOf(index);
    if (position < 0) {
      // It is in the completed group, which is closed. Open it and let the
      // next frame do the scrolling.
      if (!_completedExpanded) setState(() => _completedExpanded = true);
      return;
    }

    _state.clearRevealed();

    const rowHeight = 62.0;
    if (_scroll.hasClients) {
      final target = (position * rowHeight - rowHeight).clamp(
        0.0,
        _scroll.position.maxScrollExtent,
      );
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }

    _flashTimer?.cancel();
    setState(() => _flashing = project.items[index].text);
    _flashTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _flashing = null);
    });
  }

  /// Adds what has been typed. [starred] comes from Ctrl+Enter, for an item
  /// that matters as soon as it is written.
  void _addItem({bool starred = false}) {
    final text = _newItemController.text.trim();
    if (text.isEmpty) return;

    context.read<AppState>().addItem(widget.slug, text, starred: starred);
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

    // What the list shows, in order, so a search can be told where a row is.
    final viewOrder = [...starred, ...open, if (_completedExpanded) ...done];

    final revealed = context.watch<AppState>().revealed;
    if (revealed != null && revealed.slug == widget.slug) {
      final index = revealed.index;
      if (index < project.items.length) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _revealItem(project, viewOrder, index);
        });
      } else {
        _state.clearRevealed();
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
                    controller: _scroll,
                    slivers: [
                      // Starred first, each group draggable within itself so a
                      // drag cannot silently unstar or unpin something.
                      if (starred.isNotEmpty)
                        SliverReorderableList(
                          itemCount: starred.length,
                          onReorderItem: (oldIndex, newIndex) =>
                              context.read<AppState>().reorderSlots(
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
                              notesExpanded: _expandedNotes.contains(
                                project.items[index].text,
                              ),
                              flashing: _flashing == project.items[index].text,
                              onToggleNotes: () => _toggleNotes(
                                index,
                                project.items[index].text,
                              ),
                              onNotesChanged: (notes) => _notesChanged(
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
                            notesExpanded: _expandedNotes.contains(
                              project.items[index].text,
                            ),
                            flashing: _flashing == project.items[index].text,
                            onToggleNotes: () =>
                                _toggleNotes(index, project.items[index].text),
                            onNotesChanged: (notes) =>
                                _notesChanged(project.items[index].text, notes),
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
                              notesExpanded: _expandedNotes.contains(
                                project.items[index].text,
                              ),
                              flashing: _flashing == project.items[index].text,
                              onToggleNotes: () => _toggleNotes(
                                index,
                                project.items[index].text,
                              ),
                              onNotesChanged: (notes) => _notesChanged(
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
            onSubmitStarred: () => _addItem(starred: true),
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
    this.flashing = false,
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

  /// Marked for a moment, because a search just pointed at this row.
  final bool flashing;
  final VoidCallback onToggleNotes;

  /// Fires as the notes are edited in place, for the view to save.
  final ValueChanged<String> onNotesChanged;

  /// Starred and still open: worth picking out of the list.
  bool get highlighted => item.starred && !item.done;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<AppState>();

    // A finger gets different gestures from a mouse: a tap opens the notes in
    // place, a double tap opens the full editor, and long-press picks the row
    // up to move it — which is why the menu moves onto a button.
    final touch = TouchInput.isPrimary;

    final actions = <ContextMenuAction>[
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
          title: item.text,
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
        label: 'Move to...',
        icon: Icons.drive_file_move_outline,
        onSelected: () async {
          final project = await ProjectPicker.show(context, excludeSlug: slug);
          if (project == null || !context.mounted) return;

          final problem = await state.moveItem(slug, index, project.slug);
          if (problem == null || !context.mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(problem)));
        },
      ),
      ContextMenuAction(
        label: 'Delete',
        icon: Icons.delete_outline,
        destructive: true,
        onSelected: () => state.removeItem(slug, index),
      ),
    ];

    void openEditor() => NoteEditor.open(
      context,
      slug: slug,
      index: index,
      title: item.text,
      initialNotes: item.notes,
    );

    // Under a mouse, anywhere on the row opens the note. Under a finger a tap
    // opens the notes in place and a double tap opens the editor.
    //
    // Only the title, not the whole row: a double-tap recognizer holds the
    // gesture arena open for its window, so a row wrapped in one made every
    // button inside it — the checkbox, the star, the menu — wait a third of a
    // second before responding. The title is the part of the row that is not
    // already a control, and it stretches, so the empty space beside a short
    // one belongs to it too.
    Widget header = Row(
      children: [
        Checkbox(
          value: item.done,
          onChanged: (_) => state.toggleItem(slug, index),
        ),
        Expanded(
          child: _RowGestures(
            onTap: touch ? onToggleNotes : openEditor,
            onDoubleTap: touch ? openEditor : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: _ItemTitle(item: item),
            ),
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
        // A phone has no right-click and its long press now moves the row, so
        // the actions need a button of their own. It takes the handle's place,
        // so the row is no busier than it was.
        if (touch)
          ItemMenuButton(actions: actions, tooltip: 'Item actions')
        // On the desktop, an explicit handle rather than a long-press drag,
        // because long-press opens the context menu.
        else if (dragPosition != null)
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
    );

    // A phone moves a row by holding it and dragging, so the whole header is
    // the handle. The header only: a long press inside an open note belongs to
    // the text there. A long-press recognizer yields to a tap, so the buttons
    // in the row stay immediate.
    if (touch && dragPosition != null) {
      header = ReorderableDelayedDragStartListener(
        index: dragPosition!,
        child: header,
      );
    }

    return ItemContextMenu(
      actions: actions,
      // On a phone long-press moves the row instead, so the menu is on the
      // button at the end of it.
      longPress: !touch,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        // A Material of its own, not a decorated box: it carries the row's own
        // fill and outline, so an ink splash lands on top of them rather than
        // on the Scaffold underneath where none of it can be seen — and a row
        // held and lifted into the reorder overlay takes a Material with it,
        // which the ink there needs and would otherwise assert over.
        //
        // A starred row is tinted and outlined in the accent colour, so the
        // ones that matter are findable without reading the stars. A starred
        // item that is done has had its moment, and goes back to looking like
        // the rest.
        child: Material(
          color: flashing
              ? theme.colorScheme.tertiaryContainer
              : highlighted
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.45)
              : theme.colorScheme.surfaceContainerLowest,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: flashing
                  ? theme.colorScheme.tertiary
                  : highlighted
                  ? theme.colorScheme.primary.withValues(alpha: 0.5)
                  : theme.colorScheme.outlineVariant,
              width: flashing ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header,
              if (notesExpanded)
                Padding(
                  // Indented to start under the item's text, not its checkbox.
                  padding: const EdgeInsets.fromLTRB(36, 0, 12, 10),
                  child: _InlineNotes(
                    // Keyed by the item so that editing one note and opening
                    // another does not hand the second the first one's blocks.
                    // By text, not index: an index is reused by whichever row
                    // moves into it, which would hand the editor's blocks to a
                    // different item's note.
                    key: ValueKey('notes-$slug-${item.text}'),
                    slug: slug,
                    initialMarkdown: item.notes,
                    onChanged: onNotesChanged,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A row's taps, and the hold that picks it up to move it.
///
/// Flutter fires `onTap` for the first tap of a double tap as well, so a row
/// wired to both would expand its notes on the way to opening the editor. A
/// single tap therefore waits out the double-tap window before acting, which
/// costs it a third of a second on the phone and is the only way to tell one
/// gesture from the other. With no double tap asked for — the desktop — the
/// tap is immediate, as it always was.
class _RowGestures extends StatefulWidget {
  const _RowGestures({
    required this.child,
    required this.onTap,
    this.onDoubleTap,
  });

  final Widget child;
  final VoidCallback onTap;

  /// Null where a double tap means nothing, which also makes the single tap
  /// fire straight away.
  final VoidCallback? onDoubleTap;

  @override
  State<_RowGestures> createState() => _RowGesturesState();
}

class _RowGesturesState extends State<_RowGestures> {
  Timer? _pendingTap;

  @override
  void dispose() {
    _pendingTap?.cancel();
    super.dispose();
  }

  void _tapped() {
    if (widget.onDoubleTap == null) {
      widget.onTap();
      return;
    }
    _pendingTap?.cancel();
    _pendingTap = Timer(kDoubleTapTimeout, () {
      if (mounted) widget.onTap();
    });
  }

  void _doubleTapped() {
    _pendingTap?.cancel();
    _pendingTap = null;
    widget.onDoubleTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: _tapped,
      onDoubleTap: widget.onDoubleTap == null ? null : _doubleTapped,
      child: widget.child,
    );
  }
}

/// The editor for a note opened inside a row.
///
/// Stateful only to hold the keys the image handling needs: a note opened in
/// place can take a pasted or dropped picture, the same as one on its own
/// screen — before this it could not, which made pasting a screenshot depend
/// on which editor happened to be open.
class _InlineNotes extends StatefulWidget {
  const _InlineNotes({
    super.key,
    required this.slug,
    required this.initialMarkdown,
    required this.onChanged,
  });

  final String slug;
  final String initialMarkdown;
  final ValueChanged<String> onChanged;

  @override
  State<_InlineNotes> createState() => _InlineNotesState();
}

class _InlineNotesState extends State<_InlineNotes> {
  final _editor = GlobalKey<NoteBlocksEditorState>();
  final _images = GlobalKey<NoteImageTargetState>();

  /// A conversation reads as an exchange here too, rather than as its own
  /// signatures in raw markdown — which is what a quick back-and-forth in a
  /// list actually wants. Anything else is the block editor, as before.
  late bool _asConversation = NoteConversation.looksConversational(
    widget.initialMarkdown,
  );

  /// What the note holds now, so switching views does not lose a message.
  late String _markdown = widget.initialMarkdown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_asConversation)
          InlineConversation(
            markdown: _markdown,
            onSend: (markdown) {
              setState(() => _markdown = markdown);
              widget.onChanged(markdown);
            },
            onOpenProject: (slug) => context.read<AppState>().select(slug),
          )
        else
          NoteImageTarget(
            key: _images,
            slug: widget.slug,
            editor: _editor,
            // A row in a list has no room for a progress bar; the picture
            // appearing is the feedback.
            showProgress: false,
            child: NoteBlocksEditor(
              key: _editor,
              initialMarkdown: _markdown,
              shrinkWrap: true,
              onChanged: (markdown) {
                _markdown = markdown;
                widget.onChanged(markdown);
              },
              onPaste: () async => _images.currentState?.paste(),
              onOpenProject: (slug) => context.read<AppState>().select(slug),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              textStyle: theme.textTheme.labelSmall,
            ),
            icon: Icon(
              _asConversation ? Icons.edit_note : Icons.forum_outlined,
              size: 16,
            ),
            label: Text(_asConversation ? 'Edit as markdown' : 'Conversation'),
            onPressed: () => setState(() => _asConversation = !_asConversation),
          ),
        ),
      ],
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
    final awaiting = item.done ? const <String>[] : item.awaiting;
    if (tags.isEmpty && awaiting.isEmpty) {
      return Text(item.text, style: style);
    }

    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // A title made of nothing but tags would otherwise render an empty
        // line above the pills. The mention itself stays in the text, because
        // "@Claude pick this up" is a sentence and taking the name out of it
        // would leave it saying nothing.
        if (item.title.isNotEmpty) Text(item.title, style: style),
        for (final tag in tags) TagPill(tag: tag, faded: item.done),
        for (final name in awaiting) WaitingPill(name: name),
      ],
    );
  }
}

class _AddItemBar extends StatelessWidget {
  const _AddItemBar({
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
    required this.onSubmitStarred,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSubmit;

  /// Ctrl+Enter: add it and star it in one go, rather than adding it and then
  /// hunting for the star on a list that has just moved.
  final VoidCallback onSubmitStarred;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final touch = TouchInput.isPrimary;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(
                        LogicalKeyboardKey.enter,
                        control: true,
                      ): onSubmitStarred,
                      const SingleActivator(
                        LogicalKeyboardKey.enter,
                        meta: true,
                      ): onSubmitStarred,
                      const SingleActivator(
                        LogicalKeyboardKey.numpadEnter,
                        control: true,
                      ): onSubmitStarred,
                    },
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.done,
                      // No helperText: it hangs below the field, and a row that
                      // centres its children then sits the button lower than the
                      // box it belongs to. The hint is its own line below the
                      // row instead, where it lines up with the field.
                      decoration: const InputDecoration(
                        hintText: 'Add an item',
                      ),
                      onSubmitted: (_) => onSubmit(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Holding the button adds it starred, which is what Ctrl+Enter
                // does for a keyboard. A phone has no Ctrl, and this is the
                // same action on the control that already adds things.
                //
                // One widget owning both gestures, rather than a long-press
                // wrapped round an IconButton: two recognizers competing for
                // the same pointer left the hold going to the button's own tap
                // and the star never happening.
                Tooltip(
                  message: 'Add item — hold to add it starred',
                  child: Material(
                    color: theme.colorScheme.primary,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: onSubmit,
                      onLongPress: () {
                        HapticFeedback.mediumImpact();
                        onSubmitStarred();
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(
                          Icons.add,
                          color: theme.colorScheme.onPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 12),
              child: Text(
                touch
                    ? 'Hold + to add it starred'
                    : 'Ctrl+Enter adds it starred',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
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
          case 'archive':
            final problem = await state.archiveCompleted(project.slug);
            if (problem == null || !context.mounted) return;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(problem)));
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
        PopupMenuItem(value: 'archive', child: Text('Archive completed')),
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
