import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:provider/provider.dart';

import '../markdown/canvas_cards.dart';
import '../markdown/canvas_placement.dart';
import '../markdown/feed_days.dart';
import '../markdown/note_conversation.dart';
import '../markdown/project_links.dart';
import '../models/canvas_layout.dart';
import '../models/checklist_item.dart';
import '../models/project.dart';
import '../state/app_state.dart';
import 'canvas_screen.dart';
import 'home_shell.dart';
import 'canvas_view.dart';
import 'composer.dart';
import 'context_menu.dart';
import 'conversation_view.dart';
import 'note_blocks_editor.dart';
import 'note_editor.dart';
import 'note_images.dart';
import 'note_view.dart';
import 'project_notes_view.dart';
import 'project_picker.dart';
import 'shared_notebooks.dart';
import 'tag_pill.dart';
import 'text_prompt.dart';
import 'touch_input.dart';

/// One project's checklist: open items first, then a collapsible Completed
/// group at the bottom, mirroring Microsoft To Do's shape.
class ChecklistView extends StatefulWidget {
  const ChecklistView({super.key, required this.slug, this.showAppBar = true,
    this.openItemText});

  final String slug;
  final String? openItemText;

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

  @override
  void initState() {
    super.initState();
    if (widget.openItemText != null) _expandedNotes.add(widget.openItemText!);
  }

  /// Sections folded away, by name. A canvas is four hundred pixels tall
  /// whatever is on it, so a project with two of them is mostly canvas unless
  /// they can be put away.
  final Set<String> _collapsedSections = {};

  /// Which project's days have already been folded, so opening a feed folds
  /// everything but today once rather than every time it rebuilds — which
  /// would fold a day shut the moment you opened it.
  String? _foldedFeed;

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

  Future<void> _flushNotes(String itemText) async {
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
    await _state.setItemNotes(
      widget.slug,
      index,
      ProjectLinks.normalize(markdown, _state.projects),
    );
  }

  Future<void> _flushAllNotes() async {
    if (_newItemController.text.trim().isNotEmpty) {
      throw const UpdatePreparationException(
        'There is text waiting in the add box. Add it or clear it before restarting.',
      );
    }
    for (final itemText in _pendingNotes.keys.toList()) {
      await _flushNotes(itemText);
    }
  }

  /// Held so a note still in hand can be written while this view is going
  /// away, when reading the state off the context is no longer allowed.
  late AppState _state;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _state = context.read<AppState>();
    _state.registerEditorSave(_flushAllNotes);
  }

  @override
  void dispose() {
    _state.unregisterEditorSave(_flushAllNotes);
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

  /// What the composer will add: an item, or a `##` section of notes.
  AddKind _addKind = AddKind.task;

  /// The section a new item goes into, set by touching one and shown in the
  /// composer. Null adds at the top of the project, as it always did.
  ///
  /// Explicit rather than inferred from the focus: the composer's own field
  /// takes the focus the moment you start typing, so "wherever the cursor is"
  /// would be the composer every time. Touching a section is the intent, and
  /// the chip in the composer says where it landed.
  String? _addTarget;

  /// [_addTarget], but only while that section still exists.
  ///
  /// Resolved here rather than at each use: the composer hid the chip for a
  /// section that had been renamed away, while the add itself still sent the
  /// item to the old name — so what it said and what it did disagreed.
  String? get _resolvedTarget {
    final project = _state.projectBySlug(widget.slug);
    if (project == null) return null;
    return project.blocks.any((block) => block.title == _addTarget)
        ? _addTarget
        : null;
  }

  /// Adds what has been typed. [starred] comes from Ctrl+Enter or from holding
  /// the send button, for an item that matters as soon as it is written.
  void _addItem({bool starred = false}) {
    final text = _newItemController.text.trim();
    if (text.isEmpty) return;

    final state = context.read<AppState>();

    // In a feed, what is written goes under today, and today is made if this
    // is the first thing written in it. Nothing else has to be chosen: a feed
    // is a day at a time, so the day is never a decision.
    final project = state.projectBySlug(widget.slug);
    if (project != null &&
        project.mode == ProjectMode.feed &&
        _addKind == AddKind.task) {
      final today = FeedDays.titleFor(DateTime.now());
      if (!project.blocks.any((block) => block.title == today)) {
        state.addBlock(widget.slug, today);
        // A day made now is today, so it opens rather than arriving folded.
        _collapsedSections.remove(today);
      }
      state.addItem(widget.slug, text, starred: starred, block: today);
      _newItemController.clear();
      _newItemFocus.requestFocus();
      return;
    }

    // On a canvas, what is typed goes onto the board as a card rather than
    // into a list underneath it — the canvas is what the section is now.
    final target = _resolvedTarget;
    if (target != null && state.isCanvas(widget.slug, target)) {
      state.addCanvasCard(widget.slug, target, text);
      _newItemController.clear();
      _newItemFocus.requestFocus();
      return;
    }

    if (_addKind != AddKind.task) {
      // What was typed is the heading: a section is named, and what goes in it
      // is written underneath once it is there. Sections do not nest, so this
      // is always a section of the project however deep you were.
      //
      // A canvas is the same section with an arrangement beside it, which is
      // the only difference between the two — so adding one is adding a
      // section and saying it is a canvas.
      state.addBlock(widget.slug, text);
      if (_addKind == AddKind.canvas) {
        state.setCanvas(widget.slug, text, true);
      }
      setState(() => _addTarget = text);
    } else {
      state.addItem(
        widget.slug,
        text,
        starred: starred,
        block: _resolvedTarget,
      );
    }
    _newItemController.clear();
    // Keep focus so a list can be typed out without reaching for the field.
    _newItemFocus.requestFocus();
  }

  /// Picks a photo and adds an item holding it.
  ///
  /// The item is what was typed, or "Photo" if nothing was — an attachment has
  /// to hang on something, and an item with the picture in its notes is the
  /// thing that survives being read on GitHub.
  Future<void> _attachPhoto() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Images',
          extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'],
        ),
      ],
    );
    if (file == null || !mounted) return;

    await _attachBytes(file.name, await file.readAsBytes());
  }

  /// Ctrl+V in the add box.
  ///
  /// A picture on the clipboard becomes the item's notes, so a screenshot can
  /// be pasted straight into what is being written rather than saved, found
  /// and attached. Returns false when there is no picture, and the box takes
  /// the key back and pastes text the way it always did.
  Future<bool> _pasteIntoComposer() async {
    final image = await Pasteboard.image;
    if (image == null || image.isEmpty || !mounted) return false;

    final stamp = DateTime.now().toUtc().toIso8601String().split('.').first;
    await _attachBytes(
      'pasted-${stamp.replaceAll(RegExp('[:-]'), '')}.png',
      image,
    );
    return true;
  }

  /// Adds what is in the add box as an item, with [bytes] as its notes.
  Future<void> _attachBytes(String fileName, List<int> bytes) async {
    final state = context.read<AppState>();

    final text = _newItemController.text.trim();
    final reference = await state.attachImage(
      widget.slug,
      fileName: fileName,
      bytes: bytes,
    );
    if (reference == null || !mounted) return;

    final target = _resolvedTarget;

    // A picture put on a canvas is a card on the board, not an item in a list.
    if (target != null && state.isCanvas(widget.slug, target)) {
      await state.addCanvasCard(widget.slug, target, reference);
      if (!mounted) return;
      _newItemController.clear();
      return;
    }

    await state.addItem(
      widget.slug,
      text.isEmpty ? 'Photo' : text,
      block: target,
    );
    if (!mounted) return;
    // The new item is above the others of its section, which is where addItem
    // puts it.
    final index = state
        .projectBySlug(widget.slug)!
        .items
        .indexWhere((item) => item.block == target);
    if (index >= 0) await state.setItemNotes(widget.slug, index, reference);
    _newItemController.clear();
  }

  /// A feed opens on today, with the days before it folded away.
  ///
  /// Done once per project rather than on every build: doing it on every
  /// build would fold a day shut again the moment it was opened.
  void _foldOlderDays(Project project) {
    if (_foldedFeed == project.slug) return;
    _foldedFeed = project.slug;

    _collapsedSections
      ..clear()
      ..addAll(
        project.blocks
            .map((block) => block.title)
            .where((title) => !FeedDays.opensByDefault(title)),
      );
  }

  /// The sections in the order this project shows them: newest day first for
  /// a feed, and the order they are written in for anything else.
  List<ProjectBlock> _sectionsOf(Project project) {
    if (project.mode != ProjectMode.feed) return project.blocks;

    final byTitle = {for (final block in project.blocks) block.title: block};
    return [
      for (final title in FeedDays.order(byTitle.keys))
        if (byTitle[title] != null) byTitle[title]!,
    ];
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

    if (project.mode == ProjectMode.feed) _foldOlderDays(project);

    // A notes project is a document, not a list. The items are still in the
    // file and come back if it is switched again — this is a second view, not
    // a second format.
    if (opensAsNotes(project)) {
      return Scaffold(
        drawer: widget.showAppBar ? MobileProjectDrawer(selectedSlug: widget.slug) : null,
        appBar: widget.showAppBar
            ? AppBar(
                title: Text(project.title),
                actions: [_ProjectMenu(project: project)],
              )
            : null,
        body: ProjectNotesView(
          // Keyed by the project so switching to another one does not hand
          // the second project the first one's blocks.
          key: ValueKey('notes-${widget.slug}'),
          slug: widget.slug,
        ),
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
      // Items under a `##` heading are drawn in their own section below, in
      // the order the file has them.
      if (item.block != null) continue;
      if (item.done) {
        done.add(i);
      } else if (item.starred) {
        starred.add(i);
      } else {
        open.add(i);
      }
    }

    // What the list shows, in order, so a search can be told where a row is.
    final viewOrder = [
      ...starred,
      ...open,
      if (_completedExpanded) ...done,
      for (final block in project.blocks) ...project.indicesIn(block.title),
    ];

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

    final isFeed = project.mode == ProjectMode.feed;
    final sections = _sectionsOf(project);

    return Scaffold(
      drawer: widget.showAppBar ? MobileProjectDrawer(selectedSlug: widget.slug) : null,
      appBar: widget.showAppBar
          ? AppBar(
              title: Text(project.title),
              actions: [_ProjectMenu(project: project)],
            )
          : null,
      body: Column(
        children: [
          Expanded(
            child: project.items.isEmpty && project.blocks.isEmpty
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
                      if (sections.isNotEmpty)
                        SliverReorderableList(
                          itemCount: sections.length,
                          // A feed is in date order, which is not something
                          // to drag things out of.
                          onReorderItem: (oldIndex, newIndex) => context
                              .read<AppState>()
                              .reorderBlocks(widget.slug, oldIndex, newIndex),
                          itemBuilder: (context, position) {
                            final block = sections[position];
                            return _BlockSection(
                              key: ValueKey(
                                'block-${widget.slug}-${block.title}',
                              ),
                              slug: widget.slug,
                              block: block,
                              // No handle on a feed: it is in date order,
                              // which is not something to drag things out of,
                              // and without a handle there is no drag to
                              // reach the reorder with.
                              dragPosition: isFeed ? null : position,
                              // A day's heading is a date, so it is read
                              // rather than typed: Today, Yesterday, or the
                              // day itself.
                              dayLabel: isFeed
                                  ? FeedDays.label(block.title)
                                  : null,
                              collapsed: _collapsedSections.contains(
                                block.title,
                              ),
                              onToggleCollapsed: () => setState(() {
                                if (!_collapsedSections.remove(block.title)) {
                                  _collapsedSections.add(block.title);
                                }
                              }),
                              onTouched: () {
                                if (_addTarget == block.title) return;
                                setState(() => _addTarget = block.title);
                              },
                              indices: project.indicesIn(block.title),
                              items: project.itemsIn(block.title),
                              expandedNotes: _expandedNotes,
                              flashing: _flashing,
                              onToggleNotes: _toggleNotes,
                              onNotesChanged: _notesChanged,
                            );
                          },
                        ),
                      const SliverToBoxAdapter(child: SizedBox(height: 8)),
                    ],
                  ),
          ),
          if (project.notes.trim().isNotEmpty) _ProjectNotes(project: project),
          Composer(
            controller: _newItemController,
            focusNode: _newItemFocus,
            kind: _addKind,
            onKindChanged: (kind) => setState(() => _addKind = kind),
            onSubmit: _addItem,
            onSubmitStarred: () => _addItem(starred: true),
            onAttach: _attachPhoto,
            onPasteImage: _pasteIntoComposer,
            // A section that has been renamed or is no longer there stops
            // being the target rather than sending items to a name nothing
            // points at.
            target: _resolvedTarget,
            onClearTarget: () => setState(() => _addTarget = null),
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
      // On a phone this is the only way to open the notes in place, the
      // marker having come off the row to give the title its width.
      ContextMenuAction(
        label: notesExpanded
            ? 'Hide notes'
            : item.hasNotes
            ? 'Show notes'
            : 'Add notes',
        icon: notesExpanded ? Icons.expand_less : Icons.notes_outlined,
        onSelected: onToggleNotes,
      ),
      ContextMenuAction(
        label: 'Open in editor',
        icon: Icons.open_in_full,
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
            // Room to see the whole line. A single-line box scrolled to the
            // end of the text, so editing anything longer than the box meant
            // reading its last few words and guessing at the rest.
            minLines: 3,
            maxLines: 8,
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
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ItemTitle(
                    item: item,
                    notesExpanded: notesExpanded,
                    showNotesMarker: touch,
                  ),
                  if (state.projectBySlug(slug)?.mode == ProjectMode.feed)
                    Text(
                      [
                        if (item.createdAt != null)
                          'Created ${FeedDays.label(FeedDays.titleFor(item.createdAt!))}'
                        else if (item.block != null)
                          'Created ${FeedDays.label(item.block!)}',
                        if (item.updatedAt != null &&
                            item.updatedAt != item.createdAt)
                          FeedDays.relativeUpdate(item.updatedAt!),
                      ].join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        // Not on a phone: a tap on the row already opens the notes, and the
        // marker was a fourth control competing with the title for the width.
        // It is in the ⋮ menu instead, which is where the rest of the row's
        // actions live there.
        if (!touch)
          _NotesToggle(
            expanded: notesExpanded,
            hasNotes: item.hasNotes,
            onTap: onToggleNotes,
          ),
        // Compact, and sat right beside the menu: a default icon button keeps
        // a 48-pixel box around a 20-pixel star, and two of those at the end
        // of a phone row is most of a word's worth of title.
        IconButton(
          tooltip: item.starred ? 'Remove star' : 'Star',
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
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
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
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
                  // Indented under the item's text on a wide window, where
                  // lining up with the title reads well. On a phone the indent
                  // is most of a word per line, so the notes start near the
                  // edge and use the width instead.
                  padding: touch
                      ? const EdgeInsets.fromLTRB(2, 0, 6, 6)
                      : const EdgeInsets.fromLTRB(36, 0, 12, 8),
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
              autofocus: true,
              initialMarkdown: _markdown,
              shrinkWrap: true,
              onChanged: (markdown) {
                _markdown = markdown;
                widget.onChanged(markdown);
              },
              onPaste: () async => _images.currentState?.paste(),
              onRequestImage: () async => _images.currentState?.pickImage(),
              onOpenProject: (slug) => context.read<AppState>().select(slug),
            ),
          ),
        Row(
          children: [
            // A picture could only be attached from the full editor's
            // toolbar, which on a phone means opening the note properly
            // first — several taps to do the thing the note is open for.
            if (!_asConversation)
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: theme.textTheme.labelSmall,
                ),
                icon: const Icon(Icons.image_outlined, size: 16),
                label: const Text('Image'),
                onPressed: () => _images.currentState?.pickImage(),
              ),
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
              onPressed: () =>
                  setState(() => _asConversation = !_asConversation),
            ),
          ],
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
  const _ItemTitle({
    required this.item,
    this.notesExpanded = false,
    this.showNotesMarker = false,
  });

  final ChecklistItem item;

  /// Whether the notes are open underneath, which changes what the marker
  /// after the title is saying.
  final bool notesExpanded;

  /// Whether to say that this item has notes. Off where the row still carries
  /// the marker button that says it.
  final bool showNotesMarker;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyLarge?.copyWith(
      decoration: item.done ? TextDecoration.lineThrough : null,
      color: item.done ? theme.colorScheme.outline : null,
    );

    final tags = item.tags;
    final awaiting = item.done ? const <String>[] : item.awaiting;

    // Says there is something under this row. The marker that used to do this
    // was a button at the end of the row and took a button's width; this is
    // part of the title, wraps with it, and costs a character or two.
    //
    // Only when there is something to see: every row can be opened to write a
    // note in, so a marker on all of them would say nothing.
    final marker = showNotesMarker && item.hasNotes
        ? Icon(
            notesExpanded ? Icons.expand_less : Icons.notes,
            size: 15,
            color: item.done
                ? theme.colorScheme.outlineVariant
                : theme.colorScheme.outline,
          )
        : null;

    if (tags.isEmpty && awaiting.isEmpty && marker == null) {
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
        if (marker != null) marker,
      ],
    );
  }
}

/// One `##` section of a project: its heading, its items and its prose.
///
/// Drawn as a card like the rows it holds, so a section reads as one thing
/// rather than a title with loose items under it. The heading is a band across
/// the top and the prose is the body underneath — which is the distinction a
/// section was getting wrong: a name is typed once, a body is typed into.
///
/// Deliberately plainer inside than the ungrouped list above it — no separate
/// Completed group, and one order rather than three — because a section is
/// already a grouping and grouping inside a grouping reads as noise.
class _BlockSection extends StatelessWidget {
  const _BlockSection({
    super.key,
    required this.slug,
    required this.block,
    required this.indices,
    required this.items,
    required this.expandedNotes,
    required this.flashing,
    required this.onToggleNotes,
    required this.onNotesChanged,
    required this.onTouched,
    required this.collapsed,
    required this.onToggleCollapsed,
    this.dragPosition,
    this.dayLabel,
  });

  final String slug;
  final ProjectBlock block;

  /// What to show instead of the section's own name, where the name is not
  /// something a person typed. A feed's sections are dates, so they read as
  /// Today, Yesterday or the day itself — and are not renamed by hand.
  final String? dayLabel;

  /// Fires when this section is touched anywhere, so the composer can add
  /// into it.
  final VoidCallback onTouched;

  /// Folded away to its heading.
  final bool collapsed;
  final VoidCallback onToggleCollapsed;

  /// Where this section sits among the others, for moving it.
  final int? dragPosition;

  /// Where this section's items are in the project's flat list, so an edit
  /// still addresses the right line.
  final List<int> indices;
  final List<ChecklistItem> items;

  final Set<String> expandedNotes;
  final String? flashing;
  final void Function(int index, String itemText) onToggleNotes;
  final void Function(String itemText, String notes) onNotesChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<AppState>();
    final touch = TouchInput.isPrimary;
    final canvas = context.watch<AppState>().isCanvas(slug, block.title);

    final actions = <ContextMenuAction>[
      if (canvas)
        ContextMenuAction(
          label: 'Open full screen',
          icon: Icons.open_in_full,
          onSelected: () =>
              CanvasScreen.open(context, slug: slug, section: block.title),
        ),
      ContextMenuAction(
        label: canvas ? 'Show as notes' : 'Turn into a canvas',
        icon: canvas ? Icons.subject : Icons.dashboard_customize_outlined,
        onSelected: () => state.setCanvas(slug, block.title, !canvas),
      ),
      ContextMenuAction(
        label: 'Add an item here',
        icon: Icons.add,
        onSelected: () async {
          final text = await TextPromptDialog.show(
            context,
            title: 'New item in ${block.title}',
          );
          if (text != null) {
            await state.addItem(slug, text, block: block.title);
          }
        },
      ),
      if (!canvas)
        ContextMenuAction(
          label: 'Add an image here',
          icon: Icons.image_outlined,
          onSelected: () async {
            final file = await openFile(
              acceptedTypeGroups: const [
                XTypeGroup(
                  label: 'Images',
                  extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp'],
                ),
              ],
            );
            if (file == null) return;

            final reference = await state.attachImage(
              slug,
              fileName: file.name,
              bytes: await file.readAsBytes(),
            );
            if (reference == null) return;

            final body = block.body.trimRight();
            await state.setBlockBody(
              slug,
              block.title,
              body.isEmpty ? reference : '$body\n\n$reference',
            );
          },
        ),
      ContextMenuAction(
        label: 'Rename section',
        icon: Icons.drive_file_rename_outline,
        onSelected: () async {
          final title = await TextPromptDialog.show(
            context,
            title: 'Rename section',
            initialValue: block.title,
          );
          if (title != null) {
            await state.renameBlock(slug, block.title, title);
          }
        },
      ),
      ContextMenuAction(
        label: 'Delete section',
        icon: Icons.delete_outline,
        destructive: true,
        onSelected: () async {
          final count = items.length;
          final gone = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text('Delete “${block.title}”?'),
              // Says what goes, because this is the one action in the app
              // that takes several things at once.
              content: Text(
                count == 0
                    ? 'Its notes go with it.'
                    : 'Its notes and $count '
                          '${count == 1 ? 'item' : 'items'} go with it.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Delete'),
                ),
              ],
            ),
          );
          if (gone ?? false) await state.deleteBlock(slug, block.title);
        },
      ),
    ];

    final heading = Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: collapsed ? 'Show this section' : 'Fold this section away',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              collapsed ? Icons.chevron_right : Icons.expand_more,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            onPressed: onToggleCollapsed,
          ),
          Expanded(
            // A day is read, not typed: its name is the date, and renaming it
            // by hand would file what is under it on a different day.
            child: dayLabel != null
                // The name of a day opens it. A folded day is a name and
                // nothing else, and the obvious thing to press to see what is
                // under it is the name.
                ? InkWell(
                    onTap: onToggleCollapsed,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        dayLabel!,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  )
                : _BlockTitleField(
                    key: ValueKey('title-$slug-${block.title}'),
                    title: block.title,
                    onRename: (title) =>
                        state.renameBlock(slug, block.title, title),
                  ),
          ),
          ItemMenuButton(tooltip: 'Section actions', actions: actions),
          // A handle on every platform, unlike a row. A row is moved by
          // holding it, but a section's heading is a field you type its name
          // into, and a hold there belongs to selecting that text — so there
          // is no hold to spare and the handle has to be visible.
          if (dragPosition != null)
            ReorderableDragStartListener(
              index: dragPosition!,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(2, 10, 8, 10),
                child: Icon(
                  Icons.drag_indicator,
                  size: 20,
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
        ],
      ),
    );

    return Listener(
      // Anywhere in the section, including its items and its prose, so that
      // working in a section is enough to say where the next thing goes.
      onPointerDown: (_) => onTouched(),
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 2),
        child: Material(
          color: theme.colorScheme.surfaceContainerLowest,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading,
              if (collapsed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                  child: Text(
                    _summarise(items.length, block.body),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else ...[
                // The prose above the items, which is the order the file is
                // written in and the order a document is written in: a heading, a
                // paragraph, then a list. Always present, so a section made a
                // moment ago has somewhere to type rather than only a name.
                if (canvas)
                  _SectionCanvas(
                    key: ValueKey('canvas-$slug-${block.title}'),
                    slug: slug,
                    section: block.title,
                    body: block.body,
                  )
                else
                  Padding(
                    padding: touch
                        ? const EdgeInsets.fromLTRB(2, 4, 6, 4)
                        : const EdgeInsets.fromLTRB(10, 4, 8, 4),
                    child: _BlockBody(
                      key: ValueKey('body-$slug-${block.title}'),
                      slug: slug,
                      title: block.title,
                      initialMarkdown: block.body,
                    ),
                  ),
                for (var position = 0; position < items.length; position++)
                  _ItemTile(
                    key: ValueKey('block-${block.title}-${indices[position]}'),
                    slug: slug,
                    index: indices[position],
                    item: items[position],
                    notesExpanded: expandedNotes.contains(items[position].text),
                    flashing: flashing == items[position].text,
                    onToggleNotes: () =>
                        onToggleNotes(indices[position], items[position].text),
                    onNotesChanged: (notes) =>
                        onNotesChanged(items[position].text, notes),
                  ),
                const SizedBox(height: 4),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// What a folded section says about itself, so it is not a blank bar.
  String _summarise(int items, String body) {
    final parts = <String>[
      if (items > 0) '$items ${items == 1 ? 'item' : 'items'}',
      if (body.trim().isNotEmpty) 'notes',
    ];
    return parts.isEmpty ? 'Empty' : parts.join(' and ');
  }
}

/// A section shown as a canvas.
///
/// Reads the section's markdown as cards and the layout file as where they
/// sit, and hands both to the surface. Everything the surface moves comes back
/// as positions only — dragging never rewrites the markdown it is drawing,
/// which is what makes losing the layout cost the arrangement and nothing
/// else.
class _SectionCanvas extends StatefulWidget {
  const _SectionCanvas({
    super.key,
    required this.slug,
    required this.section,
    required this.body,
  });

  final String slug;
  final String section;
  final String body;

  @override
  State<_SectionCanvas> createState() => _SectionCanvasState();
}

class _SectionCanvasState extends State<_SectionCanvas> {
  /// The height being dragged to, kept here rather than written on every
  /// frame: a resize is one change to the layout file, not sixty.
  double? _dragHeight;

  void _resizeBy(double delta, CanvasSettings settings) {
    setState(
      () => _dragHeight = ((_dragHeight ?? settings.height) + delta).clamp(
        CanvasSettings.minHeight,
        CanvasSettings.maxHeight,
      ),
    );
  }

  void _commitResize(CanvasSettings settings) {
    final height = _dragHeight;
    setState(() => _dragHeight = null);
    if (height == null) return;
    context.read<AppState>().setCanvasSettings(
      widget.slug,
      widget.section,
      settings.copyWith(height: height),
    );
  }

  @override
  Widget build(BuildContext context) {
    final slug = widget.slug;
    final section = widget.section;
    final theme = Theme.of(context);
    final state = context.watch<AppState>();
    final settings = state.canvasSettings(slug, section);
    final cards = CanvasCards.parse(widget.body);

    if (cards.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Nothing on this canvas yet.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.open_in_full, size: 16),
                label: const Text('Open full screen to add photos'),
                onPressed: () =>
                    CanvasScreen.open(context, slug: slug, section: section),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        SizedBox(
          // A canvas inside a scrolling list needs a height of its own. How
          // tall is a matter of what is on it, so the bottom edge drags.
          height: _dragHeight ?? settings.height,
          child: CanvasView(
            slug: slug,
            section: section,
            cards: cards,
            settings: settings,
            onSettingsChanged: (value) => context
                .read<AppState>()
                .setCanvasSettings(slug, section, value),
            spots: CanvasPlacement.place(
              cards,
              state.layoutFor(slug).spotsFor(section),
            ),
            onChanged: (moved) =>
                context.read<AppState>().setCanvasSpots(slug, section, moved),
            onRemoveCard: (index) =>
                context.read<AppState>().removeCanvasCard(slug, section, index),
            onDuplicateCard: (index) => context
                .read<AppState>()
                .duplicateCanvasCard(slug, section, index),
            onEditCard: (index, markdown) => context
                .read<AppState>()
                .setCanvasCard(slug, section, index, markdown),
            shapes: state.canvasDrawing(slug, section),
            onDrawShape: (shape) =>
                context.read<AppState>().addCanvasShape(slug, section, shape),
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
            onOpenFullScreen: () =>
                CanvasScreen.open(context, slug: slug, section: section),
            onOpenLinkedNote: (fileSlug, title) {
              final state = context.read<AppState>();
              for (final project in state.projects) {
                if (project.fileSlug != fileSlug) continue;
                final index = project.items.indexWhere((item) => item.text == title);
                if (index < 0) continue;
                state.select(project.slug);
                state.revealItem(project.slug, index);
                final pane = PaneNoteScope.maybeOf(context);
                if (pane != null) {
                  pane.onOpen(project.slug, index);
                } else {
                  state.showNote(project.slug, index);
                }
                return;
              }
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('This linked note is unavailable.'),
              ));
            },
          ),
        ),
        _CanvasResizeHandle(
          onDrag: (delta) => _resizeBy(delta, settings),
          onDone: () => _commitResize(settings),
        ),
      ],
    );
  }
}

/// The bar under a canvas that drags its height.
///
/// Its own widget so the grip is a real target rather than an edge to hunt
/// for: a canvas lives in a scrolling list, and a two-pixel edge there would
/// be a scroll half the time.
class _CanvasResizeHandle extends StatelessWidget {
  const _CanvasResizeHandle({required this.onDrag, required this.onDone});

  final ValueChanged<double> onDrag;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // From where the finger lands rather than 18 pixels later, which on a
        // short drag was the whole drag.
        dragStartBehavior: DragStartBehavior.down,
        onVerticalDragUpdate: (details) => onDrag(details.delta.dy),
        onVerticalDragEnd: (_) => onDone(),
        onVerticalDragCancel: onDone,
        child: Tooltip(
          message: 'Drag to resize the canvas',
          child: SizedBox(
            height: 18,
            child: Center(
              child: Container(
                width: 48,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A section's name, typed in place.
///
/// The name used to be reachable only through Rename, which made a section
/// feel like something declared rather than something written. This is an
/// ordinary field that happens to look like a heading. It commits when it
/// loses focus rather than per keystroke: a rename carries the section's items
/// with it, so typing one would rewrite the file through every half-finished
/// name on the way.
class _BlockTitleField extends StatefulWidget {
  const _BlockTitleField({
    super.key,
    required this.title,
    required this.onRename,
  });

  final String title;
  final ValueChanged<String> onRename;

  @override
  State<_BlockTitleField> createState() => _BlockTitleFieldState();
}

class _BlockTitleFieldState extends State<_BlockTitleField> {
  late final _controller = TextEditingController(text: widget.title);
  late final FocusNode _focus = FocusNode()..addListener(_focusChanged);

  void _focusChanged() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    final title = _controller.text.trim();
    if (title.isEmpty) {
      // A section has to be called something, since its name is what its items
      // point at. Put the old one back rather than write a heading that cannot
      // be addressed.
      _controller.text = widget.title;
      return;
    }
    if (title != widget.title) widget.onRename(title);
  }

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _commit();
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return TextField(
      controller: _controller,
      focusNode: _focus,
      textCapitalization: TextCapitalization.sentences,
      textInputAction: TextInputAction.done,
      style: theme.textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w700,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      decoration: const InputDecoration(
        hintText: 'Section name',
        border: InputBorder.none,
        isDense: true,
        contentPadding: EdgeInsets.symmetric(vertical: 10),
      ),
      onSubmitted: (_) => _focus.unfocus(),
    );
  }
}

/// The prose under a `##` heading, edited in place.
class _BlockBody extends StatefulWidget {
  const _BlockBody({
    super.key,
    required this.slug,
    required this.title,
    required this.initialMarkdown,
  });

  final String slug;
  final String title;
  final String initialMarkdown;

  @override
  State<_BlockBody> createState() => _BlockBodyState();
}

class _BlockBodyState extends State<_BlockBody> {
  final _editor = GlobalKey<NoteBlocksEditorState>();
  final _images = GlobalKey<NoteImageTargetState>();

  String? _pending;
  Timer? _autosave;
  late AppState _state;

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
    await _state.setBlockBody(
      widget.slug,
      widget.title,
      ProjectLinks.normalize(markdown, _state.projects),
    );
  }

  @override
  Widget build(BuildContext context) {
    return NoteImageTarget(
      key: _images,
      slug: widget.slug,
      editor: _editor,
      showProgress: false,
      child: NoteBlocksEditor(
        key: _editor,
        initialMarkdown: widget.initialMarkdown,
        shrinkWrap: true,
        placeholder: 'Write here…',
        onChanged: _changed,
        onPaste: () async => _images.currentState?.paste(),
        onRequestImage: () async => _images.currentState?.pickImage(),
        onOpenProject: (slug) => context.read<AppState>().select(slug),
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
          case 'mode':
            await state.setMode(
              project.slug,
              project.mode == ProjectMode.notes
                  ? ProjectMode.tasks
                  : ProjectMode.notes,
            );
          case 'feed':
            await state.setMode(
              project.slug,
              project.mode == ProjectMode.feed
                  ? ProjectMode.tasks
                  : ProjectMode.feed,
            );
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
          case 'share':
            await ShareProjectDialog.show(context, project);
          case 'unshare':
            await ShareProjectDialog.stopSharing(context, project);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'mode',
          child: Text(
            project.mode == ProjectMode.notes
                ? 'Turn into a checklist'
                : 'Turn into notes',
          ),
        ),
        PopupMenuItem(
          value: 'feed',
          child: Text(
            project.mode == ProjectMode.feed
                ? 'Turn into a checklist'
                : 'Turn into a feed',
          ),
        ),
        if (project.mode != ProjectMode.notes) ...const [
          PopupMenuItem(value: 'archive', child: Text('Archive completed')),
          PopupMenuItem(value: 'notes', child: Text('Project notes')),
        ],
        if (project.isShared)
          const PopupMenuItem(value: 'unshare', child: Text('Stop sharing'))
        else
          const PopupMenuItem(value: 'share', child: Text('Share\u2026')),
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
