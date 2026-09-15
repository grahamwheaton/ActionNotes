import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/project.dart';
import '../state/app_state.dart';
import 'text_prompt.dart';

class ChecklistScreen extends StatefulWidget {
  const ChecklistScreen({super.key, required this.slug});

  final String slug;

  @override
  State<ChecklistScreen> createState() => _ChecklistScreenState();
}

class _ChecklistScreenState extends State<ChecklistScreen> {
  final _newItemController = TextEditingController();
  final _newItemFocus = FocusNode();

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
        appBar: AppBar(),
        body: const Center(child: Text('This project is no longer here.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(project.title),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) => _onMenu(value, project),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'clear', child: Text('Clear completed')),
              PopupMenuItem(value: 'notes', child: Text('Edit notes')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: project.items.isEmpty
                ? const _EmptyChecklist()
                : ReorderableListView.builder(
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: project.items.length,
                    onReorderItem: (oldIndex, newIndex) => context
                        .read<AppState>()
                        .reorderItems(widget.slug, oldIndex, newIndex),
                    itemBuilder: (context, index) => _ItemTile(
                      key: ValueKey('${widget.slug}-$index-${project.items[index].text}'),
                      slug: widget.slug,
                      index: index,
                      project: project,
                    ),
                  ),
          ),
          if (project.notes.trim().isNotEmpty) _NotesPreview(project: project),
          _AddItemBar(
            controller: _newItemController,
            focusNode: _newItemFocus,
            onSubmit: _addItem,
          ),
        ],
      ),
    );
  }

  Future<void> _onMenu(String value, Project project) async {
    final state = context.read<AppState>();

    if (value == 'clear') {
      await state.clearCompleted(widget.slug);
      return;
    }

    final notes = await TextPromptDialog.show(
      context,
      title: 'Notes',
      initialValue: project.notes,
      hintText: 'Free text, saved under the checklist in the file',
      maxLines: 8,
      minLines: 4,
      allowEmpty: true,
    );

    if (notes != null) await state.setNotes(widget.slug, notes);
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({
    super.key,
    required this.slug,
    required this.index,
    required this.project,
  });

  final String slug;
  final int index;
  final Project project;

  @override
  Widget build(BuildContext context) {
    final item = project.items[index];
    final theme = Theme.of(context);
    final state = context.read<AppState>();

    return Dismissible(
      key: ValueKey('dismiss-$slug-$index-${item.text}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        color: theme.colorScheme.errorContainer,
        padding: const EdgeInsets.only(right: 24),
        child: Icon(Icons.delete_outline, color: theme.colorScheme.onErrorContainer),
      ),
      onDismissed: (_) => state.removeItem(slug, index),
      child: CheckboxListTile(
        value: item.done,
        onChanged: (_) => state.toggleItem(slug, index),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: const EdgeInsets.only(left: 12, right: 8),
        title: GestureDetector(
          onTap: () => _editItem(context, slug, index, item.text),
          child: Text(
            item.text,
            style: theme.textTheme.bodyLarge?.copyWith(
              decoration: item.done ? TextDecoration.lineThrough : null,
              color: item.done ? theme.colorScheme.outline : null,
            ),
          ),
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

class _NotesPreview extends StatelessWidget {
  const _NotesPreview({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        project.notes.trim(),
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
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

Future<void> _editItem(
  BuildContext context,
  String slug,
  int index,
  String current,
) async {
  final state = context.read<AppState>();

  final text = await TextPromptDialog.show(
    context,
    title: 'Edit item',
    initialValue: current,
  );

  if (text != null) await state.editItem(slug, index, text);
}
