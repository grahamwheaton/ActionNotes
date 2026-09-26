import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/kanban_board.dart';
import '../models/project.dart';
import '../state/app_state.dart';
import 'checklist_view.dart';

/// A board made of live project columns. The columns reference projects;
/// editing an item here changes its original project.
class KanbanView extends StatelessWidget {
  const KanbanView({super.key, required this.board});

  final Project board;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final columns = KanbanBoard.columns(board);

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
          Expanded(child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var index = 0; index < columns.length; index++)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: _KanbanColumn(
                      column: columns[index],
                      project: state.projectBySlug(columns[index].slug),
                      onChanged: (next) {
                        final updated = [...columns]..[index] = next;
                        state.setKanbanColumns(board.slug, updated);
                      },
                      onRemove: () {
                        final updated = [...columns]..removeAt(index);
                        state.setKanbanColumns(board.slug, updated);
                      },
                    ),
                  ),
              ],
            ),
          )),
        ]),
      ),
    );
  }
}

class _KanbanColumn extends StatelessWidget {
  const _KanbanColumn({required this.column, required this.project,
    required this.onChanged, required this.onRemove});

  final KanbanColumn column;
  final Project? project;
  final ValueChanged<KanbanColumn> onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final source = project;
    final items = source == null ? const <int>[] : [
      for (var i = 0; i < source.items.length; i++)
        if ((!column.onlyStarred || source.items[i].starred) &&
            (!column.hideCompleted || !source.items[i].done)) i,
    ];

    return SizedBox(
      width: 280,
      child: Card(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
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
                  const PopupMenuDivider(),
                  const PopupMenuItem(value: 'remove', child: Text('Remove column')),
                ],
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 620),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: items.length,
                itemBuilder: (context, position) {
                  final index = items[position];
                  final item = source!.items[index];
                  return ListTile(
                    dense: true,
                    leading: Icon(item.done ? Icons.check_box : Icons.check_box_outline_blank,
                      size: 18, color: theme.colorScheme.primary),
                    title: Text(item.title, maxLines: 3, overflow: TextOverflow.ellipsis),
                    trailing: item.starred ? const Icon(Icons.star, size: 16) : null,
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => ChecklistView(
                        slug: source.slug, openItemText: item.text),
                    )),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
