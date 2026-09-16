import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/checklist_item.dart';
import '../models/project.dart';
import '../state/app_state.dart';
import 'context_menu.dart';
import 'note_editor.dart';
import 'note_view.dart';
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

  @override
  void dispose() {
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
    // though the view is grouped.
    final open = <int>[];
    final done = <int>[];
    for (var i = 0; i < project.items.length; i++) {
      (project.items[i].done ? done : open).add(i);
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
                      // Only open items are draggable; the completed group
                      // below is a plain list.
                      SliverReorderableList(
                        itemCount: open.length,
                        onReorderItem: (oldIndex, newIndex) => context
                            .read<AppState>()
                            .reorderOpenItems(widget.slug, oldIndex, newIndex),
                        itemBuilder: (context, position) {
                          final index = open[position];
                          return _ItemTile(
                            key: ValueKey('open-${widget.slug}-$index'),
                            slug: widget.slug,
                            index: index,
                            item: project.items[index],
                            dragPosition: position,
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
    this.dragPosition,
  });

  final String slug;

  /// Index into the project's full item list, so edits hit the right line
  /// even though the view is grouped.
  final int index;
  final ChecklistItem item;

  /// Position within the draggable open items, or null for a completed item.
  final int? dragPosition;

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
          label: 'Delete',
          icon: Icons.delete_outline,
          destructive: true,
          onSelected: () => state.removeItem(slug, index),
        ),
      ],
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Checkbox(
                  value: item.done,
                  onChanged: (_) => state.toggleItem(slug, index),
                ),
                Expanded(
                  child: InkWell(
                    onTap: () => NoteEditor.open(
                      context,
                      slug: slug,
                      index: index,
                      title: item.text,
                      initialNotes: item.notes,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.text,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              decoration:
                                  item.done ? TextDecoration.lineThrough : null,
                              color:
                                  item.done ? theme.colorScheme.outline : null,
                            ),
                          ),
                          if (item.hasNotes)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.notes,
                                    size: 13,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Notes',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color:
                                          theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
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
          ],
        ),
      ),
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
        child: NoteView(markdown: project.notes.trim()),
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
