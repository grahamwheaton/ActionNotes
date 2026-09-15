import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/project.dart';
import '../state/app_state.dart';
import 'checklist_screen.dart';
import 'settings_screen.dart';
import 'text_prompt.dart';

class ProjectsScreen extends StatelessWidget {
  const ProjectsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Projects'),
        actions: [
          if (state.syncing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            IconButton(
              icon: Badge(
                isLabelVisible: state.pendingCount > 0,
                label: Text('${state.pendingCount}'),
                child: const Icon(Icons.sync),
              ),
              tooltip: 'Sync with GitHub',
              onPressed: state.sync,
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _newProject(context),
        icon: const Icon(Icons.add),
        label: const Text('New project'),
      ),
      body: _Body(state: state),
    );
  }

  static Future<void> _newProject(BuildContext context) async {
    final title = await TextPromptDialog.show(
      context,
      title: 'New project',
      hintText: 'Project name',
    );
    if (title == null || !context.mounted) return;

    final state = context.read<AppState>();
    final project = await state.createProject(title);
    if (!context.mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChecklistScreen(slug: project.slug)),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    if (state.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        if (state.message != null) _MessageBar(message: state.message!),
        if (!state.isConfigured) const _SetupPrompt(),
        Expanded(
          child: state.projects.isEmpty
              ? const _EmptyState()
              : RefreshIndicator(
                  onRefresh: state.sync,
                  child: ListView.separated(
                    padding: const EdgeInsets.only(bottom: 96),
                    itemCount: state.projects.length,
                    separatorBuilder: (_, __) => const Divider(indent: 20, endIndent: 20),
                    itemBuilder: (context, index) =>
                        _ProjectTile(project: state.projects[index]),
                  ),
                ),
        ),
      ],
    );
  }
}

class _ProjectTile extends StatelessWidget {
  const _ProjectTile({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = project.items.length;
    final done = project.doneCount;

    return ListTile(
      title: Text(
        project.title,
        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        total == 0 ? 'No items yet' : '$done of $total done',
        style: theme.textTheme.bodySmall,
      ),
      trailing: project.dirty
          ? Tooltip(
              message: 'Not yet pushed to GitHub',
              child: Icon(
                Icons.cloud_upload_outlined,
                size: 18,
                color: theme.colorScheme.outline,
              ),
            )
          : const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ChecklistScreen(slug: project.slug)),
      ),
      onLongPress: () => _showProjectMenu(context, project),
    );
  }
}

class _MessageBar extends StatelessWidget {
  const _MessageBar({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: scheme.onErrorContainer,
            onPressed: context.read<AppState>().dismissMessage,
          ),
        ],
      ),
    );
  }
}

class _SetupPrompt extends StatelessWidget {
  const _SetupPrompt();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      color: scheme.secondaryContainer,
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Working on this device only. Connect a GitHub repo to sync.',
              style: TextStyle(color: scheme.onSecondaryContainer),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.checklist_rtl,
              size: 56,
              color: theme.colorScheme.outlineVariant,
            ),
            const SizedBox(height: 16),
            Text('No projects yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Each project is one markdown file in your repo.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _showProjectMenu(BuildContext context, Project project) async {
  final state = context.read<AppState>();

  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.drive_file_rename_outline),
            title: const Text('Rename'),
            onTap: () => Navigator.of(sheetContext).pop('rename'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Delete'),
            onTap: () => Navigator.of(sheetContext).pop('delete'),
          ),
        ],
      ),
    ),
  );

  if (action == null || !context.mounted) return;

  if (action == 'rename') {
    final title = await TextPromptDialog.show(
      context,
      title: 'Rename project',
      initialValue: project.title,
      hintText: 'Project name',
    );
    if (title != null) await state.renameProject(project.slug, title);
    return;
  }

  if (!context.mounted) return;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Delete "${project.title}"?'),
      content: const Text(
        'The markdown file is removed from GitHub too. This cannot be undone '
        'from the app, though the commit history keeps a copy.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );

  if (confirmed == true) await state.deleteProject(project.slug);
}
