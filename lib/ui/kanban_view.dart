import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/kanban_board.dart';
import '../models/project.dart';
import '../state/app_state.dart';
import 'checklist_view.dart';
import 'text_prompt.dart';
import 'touch_input.dart';

/// A board made of live project columns. The columns reference projects;
/// editing an item here changes its original project.
class KanbanView extends StatefulWidget {
  const KanbanView({super.key, required this.board});

  final Project board;

  @override
  State<KanbanView> createState() => _KanbanViewState();
}

class _KanbanViewState extends State<KanbanView> {
  // The size while an edge is being dragged; saved once when it is let go.
  double? _dragWidth;
  double? _dragHeight;

  void _saveSize(AppState state, KanbanSize saved) {
    final next = KanbanSize(
      width: _dragWidth ?? saved.width,
      height: _dragHeight ?? saved.height,
    );
    setState(() {
      _dragWidth = null;
      _dragHeight = null;
    });
    state.setKanbanSize(widget.board.slug, next);
  }

  @override
  Widget build(BuildContext context) {
    final board = widget.board;
    final state = context.watch<AppState>();
    final columns = KanbanBoard.columns(board);
    final presets = KanbanBoard.presets(board);
    final size = KanbanBoard.size(board);

    void add(String slug) {
      if (slug == board.slug || columns.any((column) => column.slug == slug)) return;
      state.setKanbanColumns(board.slug, [...columns, KanbanColumn(slug)]);
    }

    return DragTarget<String>(
      onWillAcceptWithDetails: (details) =>
          details.data != board.slug &&
          state.projectBySlug(details.data) != null &&
          !columns.any((column) => column.slug == details.data),
      onAcceptWithDetails: (details) => add(details.data),
      builder: (context, candidates, rejected) => Container(
        color: candidates.isNotEmpty
            ? Theme.of(context).colorScheme.primaryContainer : null,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              const Expanded(child: Text('Drag a project here, or add a column')),
              PopupMenuButton<String>(
                tooltip: 'Filter presets',
                icon: const Icon(Icons.bookmarks_outlined),
                onSelected: (choice) async {
                  if (choice == 'save') {
                    final name = await TextPromptDialog.show(context,
                      title: 'Save filter preset', hintText: 'Preset name');
                    if (name == null || name.trim().isEmpty) return;
                    await state.setKanbanPresets(board.slug,
                      {...presets, name.trim(): [...columns]});
                  } else if (choice.startsWith('delete:')) {
                    final next = {...presets}..remove(choice.substring(7));
                    await state.setKanbanPresets(board.slug, next);
                  } else if (choice.startsWith('apply:')) {
                    await state.setKanbanColumns(board.slug,
                      presets[choice.substring(6)]!);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'save',
                    child: Text('Save current filters…')),
                  if (presets.isNotEmpty) const PopupMenuDivider(),
                  for (final name in presets.keys) ...[
                    PopupMenuItem(value: 'apply:$name', child: Text(name)),
                    PopupMenuItem(value: 'delete:$name',
                      child: Text('Delete “$name”')),
                  ],
                ],
              ),
              PopupMenuButton<String>(
                tooltip: 'Add project column',
                icon: const Icon(Icons.add),
                onSelected: add,
                itemBuilder: (_) => [
                  for (final project in state.projects)
                    if (project.slug != board.slug &&
                        !columns.any((column) => column.slug == project.slug))
                      PopupMenuItem(value: project.slug, child: Text(project.title)),
                ],
              ),
            ]),
          ),
          Expanded(child: LayoutBuilder(
            builder: (context, constraints) {
              // Columns fill the screen unless someone has sized them.
              final fill = (constraints.maxHeight - 24)
                  .clamp(KanbanSize.minHeight, double.infinity);
              final height = _dragHeight ?? size.height ?? fill;
              final width = _dragWidth ?? size.width;
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.all(12),
                child: SingleChildScrollView(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var index = 0; index < columns.length; index++)
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: _Resizable(
                            onWidth: (dx) => setState(() => _dragWidth =
                                (width + dx).clamp(KanbanSize.minWidth,
                                    KanbanSize.maxWidth)),
                            onHeight: (dy) => setState(() => _dragHeight =
                                (height + dy).clamp(KanbanSize.minHeight,
                                    4000.0)),
                            onEnd: () => _saveSize(state, size),
                            onResetWidth: () => state.setKanbanSize(
                                widget.board.slug,
                                KanbanSize(height: size.height)),
                            onResetHeight: () => state.setKanbanSize(
                                widget.board.slug,
                                KanbanSize(width: size.width)),
                            child: _KanbanColumn(
                              column: columns[index],
                              width: width,
                              height: height,
                              project:
                                  state.projectBySlug(columns[index].slug),
                              onChanged: (next) {
                                final updated = [...columns]..[index] = next;
                                state.setKanbanColumns(
                                    widget.board.slug, updated);
                              },
                              onRemove: () {
                                final updated = [...columns]..removeAt(index);
                                state.setKanbanColumns(
                                    widget.board.slug, updated);
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          )),
        ]),
      ),
    );
  }
}

/// Colours a column can be given, alongside the theme's own.
const _columnColors = <int>[
  0xFFFFCDD2, 0xFFFFE0B2, 0xFFFFF9C4, 0xFFC8E6C9,
  0xFFB2EBF2, 0xFFBBDEFB, 0xFFD1C4E9, 0xFFF8BBD0,
];

/// Handles on the right and bottom edges of a column. Every column shares
/// one size, so dragging any edge resizes them all; a double click puts that
/// dimension back to its default.
class _Resizable extends StatelessWidget {
  const _Resizable({required this.child, required this.onWidth,
    required this.onHeight, required this.onEnd, required this.onResetWidth,
    required this.onResetHeight});

  final Widget child;
  final ValueChanged<double> onWidth;
  final ValueChanged<double> onHeight;
  final VoidCallback onEnd;
  final VoidCallback onResetWidth;
  final VoidCallback onResetHeight;

  @override
  Widget build(BuildContext context) {
    Widget edge(MouseCursor cursor, String tip, {required bool vertical}) =>
        Tooltip(
          message: tip,
          waitDuration: const Duration(milliseconds: 800),
          child: MouseRegion(
            cursor: cursor,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onDoubleTap: vertical ? onResetWidth : onResetHeight,
              onHorizontalDragUpdate:
                  vertical ? (d) => onWidth(d.primaryDelta ?? 0) : null,
              onHorizontalDragEnd: vertical ? (_) => onEnd() : null,
              onVerticalDragUpdate:
                  vertical ? null : (d) => onHeight(d.primaryDelta ?? 0),
              onVerticalDragEnd: vertical ? null : (_) => onEnd(),
            ),
          ),
        );

    return Stack(clipBehavior: Clip.none, children: [
      child,
      Positioned(right: -8, top: 0, bottom: 0, width: 12,
        child: edge(SystemMouseCursors.resizeColumn,
          'Drag to resize all columns', vertical: true)),
      Positioned(left: 0, right: 0, bottom: -8, height: 12,
        child: edge(SystemMouseCursors.resizeRow,
          'Drag to resize all columns', vertical: false)),
    ]);
  }
}

class _KanbanColumn extends StatelessWidget {
  const _KanbanColumn({required this.column, required this.project,
    required this.width, required this.height,
    required this.onChanged, required this.onRemove});

  final KanbanColumn column;
  final Project? project;
  final double width;
  final double height;
  final ValueChanged<KanbanColumn> onChanged;
  final VoidCallback onRemove;

  Future<void> _pickColor(BuildContext context) async {
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Column colour'),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Wrap(spacing: 10, runSpacing: 10, children: [
              for (final value in _columnColors)
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => Navigator.pop(context, value),
                  child: CircleAvatar(
                    radius: 18,
                    backgroundColor: Color(value),
                    child: column.color == value
                        ? const Icon(Icons.check, color: Colors.black54)
                        : null,
                  ),
                ),
            ]),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, -1),
            child: const Text('Use the theme colour'),
          ),
        ],
      ),
    );
    if (picked == null) return;
    onChanged(picked == -1
        ? column.copyWith(clearColor: true)
        : column.copyWith(color: picked));
  }

  Future<void> _move(BuildContext context, NoteTarget item) async {
    final state = context.read<AppState>();
    final problem = await state.moveItem(item.slug, item.index, column.slug);
    if (problem == null || !context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(problem)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<AppState>();
    final source = project;
    final items = source == null ? const <int>[] : [
      for (var i = 0; i < source.items.length; i++)
        if ((!column.onlyStarred || source.items[i].starred) &&
            (!column.hideCompleted || !source.items[i].done)) i,
    ];

    // A chosen colour is a light pastel, so text on it is always dark, in
    // either theme.
    final tint = column.color == null ? null : Color(column.color!);
    final onTint = tint == null ? null : Colors.black87;
    final touch = TouchInput.isPrimary;

    return DragTarget<NoteTarget>(
      onWillAcceptWithDetails: (details) =>
          source != null && details.data.slug != column.slug,
      onAcceptWithDetails: (details) => _move(context, details.data),
      builder: (context, incoming, _) => SizedBox(
      width: width,
      height: height,
      child: Card(
        color: tint,
        shape: incoming.isEmpty ? null : RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: theme.colorScheme.primary, width: 2),
        ),
        child: IconTheme.merge(
          data: IconThemeData(color: onTint),
          child: DefaultTextStyle.merge(
          style: TextStyle(color: onTint),
          child: Column(
          children: [
            ListTile(
              textColor: onTint,
              iconColor: onTint,
              title: Text(source?.title ?? 'Missing project'),
              subtitle: Text('${items.length} items'),
              trailing: PopupMenuButton<String>(
                tooltip: 'Column filters',
                onSelected: (value) {
                  switch (value) {
                    case 'starred':
                      onChanged(column.copyWith(onlyStarred: !column.onlyStarred));
                    case 'completed':
                      onChanged(column.copyWith(hideCompleted: !column.hideCompleted));
                    case 'color':
                      _pickColor(context);
                    case 'remove':
                      onRemove();
                  }
                },
                itemBuilder: (_) => [
                  CheckedPopupMenuItem(
                    value: 'starred', checked: column.onlyStarred,
                    child: const Text('Only starred'),
                  ),
                  CheckedPopupMenuItem(
                    value: 'completed', checked: column.hideCompleted,
                    child: const Text('Hide completed'),
                  ),
                  const PopupMenuItem(value: 'color', child: Text('Colour…')),
                  const PopupMenuDivider(),
                  const PopupMenuItem(value: 'remove', child: Text('Remove column')),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, position) {
                  final index = items[position];
                  final item = source!.items[index];
                  final tile = ListTile(
                    dense: true,
                    textColor: onTint,
                    leading: IconButton(
                      tooltip: item.done ? 'Mark not done' : 'Mark done',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(item.done
                          ? Icons.check_box : Icons.check_box_outline_blank,
                        size: 18, color: onTint ?? theme.colorScheme.primary),
                      onPressed: () => state.toggleItem(source.slug, index),
                    ),
                    title: Text(item.title, maxLines: 3, overflow: TextOverflow.ellipsis),
                    trailing: IconButton(
                      tooltip: item.starred ? 'Remove star' : 'Star',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(item.starred ? Icons.star : Icons.star_border,
                        size: 18,
                        color: item.starred
                            ? (onTint ?? theme.colorScheme.primary)
                            : (onTint?.withValues(alpha: 0.5) ??
                                theme.colorScheme.outline)),
                      onPressed: () => state.toggleStar(source.slug, index),
                    ),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => ChecklistView(
                        slug: source.slug, openItemText: item.text),
                    )),
                  );
                  final target = NoteTarget(source.slug, index);
                  final feedback = Material(
                    elevation: 4,
                    color: tint ?? theme.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(width: width - 16, child: tile),
                  );
                  final faded = Opacity(opacity: 0.4, child: tile);
                  // A finger holds a card to pick it up, since a plain drag
                  // scrolls the column; a mouse just drags it.
                  return touch
                      ? LongPressDraggable<NoteTarget>(data: target,
                          feedback: feedback, childWhenDragging: faded,
                          child: tile)
                      : Draggable<NoteTarget>(data: target,
                          feedback: feedback, childWhenDragging: faded,
                          child: tile);
                },
              ),
            ),
          ],
        ),
        ),
        ),
      ),
    ),
    );
  }
}
