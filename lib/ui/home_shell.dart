import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/project.dart';
import '../state/app_state.dart';
import '../storage/sync_service.dart';
import 'checklist_view.dart';
import 'conflict_dialog.dart';
import 'context_menu.dart';
import 'settings_screen.dart';
import 'text_prompt.dart';

/// Wide windows get a sidebar of projects beside the open checklist; narrow
/// ones keep the phone behaviour of pushing the checklist onto the stack.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key});

  /// Below this width the sidebar would leave too little room for the list.
  static const sidebarBreakpoint = 720.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth >= sidebarBreakpoint
          ? const _TwoPaneLayout()
          : const _SinglePaneLayout(),
    );
  }
}

class _TwoPaneLayout extends StatelessWidget {
  const _TwoPaneLayout();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    // Fall back to the first project so the detail pane is never blank when
    // there is something to show.
    final selected = state.projectBySlug(state.selectedSlug ?? '') ??
        (state.projects.isEmpty ? null : state.projects.first);

    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: 280,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                border: Border(
                  right: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
              ),
              child: ProjectSidebar(selectedSlug: selected?.slug),
            ),
          ),
          Expanded(
            child: selected == null
                ? const _NoProjectSelected()
                : Column(
                    children: [
                      _DetailHeader(project: selected),
                      Expanded(
                        child: ChecklistView(
                          // Keyed so switching project rebuilds the view's
                          // own state rather than reusing the last one's.
                          key: ValueKey(selected.slug),
                          slug: selected.slug,
                          showAppBar: false,
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _DetailHeader extends StatelessWidget {
  const _DetailHeader({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = project.items.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  project.title,
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  total == 0
                      ? 'No items yet'
                      : '${project.doneCount} of $total done',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Clear completed',
            icon: const Icon(Icons.playlist_remove),
            onPressed: () =>
                context.read<AppState>().clearCompleted(project.slug),
          ),
        ],
      ),
    );
  }
}

class _SinglePaneLayout extends StatelessWidget {
  const _SinglePaneLayout();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Projects'),
        actions: const [_SyncAction(), _SettingsAction()],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => createProject(context, openAfter: true),
        icon: const Icon(Icons.add),
        label: const Text('New project'),
      ),
      body: const ProjectSidebar(selectedSlug: null, pushOnTap: true),
    );
  }
}

/// The left-hand list of projects. Doubles as the whole screen on a phone.
class ProjectSidebar extends StatelessWidget {
  const ProjectSidebar({
    super.key,
    required this.selectedSlug,
    this.pushOnTap = false,
  });

  final String? selectedSlug;

  /// True on a phone, where tapping a project opens it as a new screen.
  final bool pushOnTap;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    if (state.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        if (!pushOnTap) const _SidebarHeader(),
        for (final conflict in state.conflicts)
          _ConflictBar(conflict: conflict),
        if (state.message != null) _MessageBar(message: state.message!),
        if (!state.isConfigured) const _SetupPrompt(),
        Expanded(
          child: state.projects.isEmpty
              ? const _NoProjects()
              : RefreshIndicator(
                  onRefresh: state.sync,
                  child: ListView.builder(
                    padding: EdgeInsets.only(bottom: pushOnTap ? 96 : 12),
                    itemCount: state.projects.length,
                    itemBuilder: (context, index) => _ProjectTile(
                      project: state.projects[index],
                      selected: state.projects[index].slug == selectedSlug,
                      pushOnTap: pushOnTap,
                    ),
                  ),
                ),
        ),
        if (!pushOnTap) const _SidebarFooter(),
      ],
    );
  }
}

class _SidebarHeader extends StatelessWidget {
  const _SidebarHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'ActionNotes',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const _SyncAction(),
          const _SettingsAction(),
        ],
      ),
    );
  }
}

class _SidebarFooter extends StatelessWidget {
  const _SidebarFooter();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: SizedBox(
        width: double.infinity,
        child: TextButton.icon(
          onPressed: () => createProject(context),
          icon: const Icon(Icons.add),
          label: const Text('New project'),
          style: TextButton.styleFrom(alignment: Alignment.centerLeft),
        ),
      ),
    );
  }
}

class _ProjectTile extends StatelessWidget {
  const _ProjectTile({
    required this.project,
    required this.selected,
    required this.pushOnTap,
  });

  final Project project;
  final bool selected;
  final bool pushOnTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<AppState>();
    final total = project.items.length;
    final open = total - project.doneCount;

    return ItemContextMenu(
      actions: [
        ContextMenuAction(
          label: 'Rename',
          icon: Icons.drive_file_rename_outline,
          onSelected: () async {
            final title = await TextPromptDialog.show(
              context,
              title: 'Rename project',
              initialValue: project.title,
              hintText: 'Project name',
            );
            if (title != null) await state.renameProject(project.slug, title);
          },
        ),
        ContextMenuAction(
          label: 'Delete',
          icon: Icons.delete_outline,
          destructive: true,
          onSelected: () => confirmDeleteProject(context, project),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Material(
          color: selected
              ? theme.colorScheme.secondaryContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () {
              if (pushOnTap) {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ChecklistView(slug: project.slug),
                  ),
                );
              } else {
                state.select(project.slug);
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    Icons.checklist,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      project.title,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (project.dirty)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Icon(
                        Icons.cloud_upload_outlined,
                        size: 14,
                        color: theme.colorScheme.outline,
                      ),
                    )
                  else if (open > 0)
                    Text(
                      '$open',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
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

class _SyncAction extends StatelessWidget {
  const _SyncAction();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    if (state.syncing) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    return IconButton(
      tooltip: 'Sync with GitHub',
      icon: Badge(
        isLabelVisible: state.pendingCount > 0,
        label: Text('${state.pendingCount}'),
        child: const Icon(Icons.sync),
      ),
      onPressed: state.sync,
    );
  }
}

class _SettingsAction extends StatelessWidget {
  const _SettingsAction();

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Settings',
      icon: const Icon(Icons.settings_outlined),
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const SettingsScreen()),
      ),
    );
  }
}

/// A conflict is a decision, not an error, so it gets an action rather than a
/// dismiss button — dismissing would leave the project unable to sync.
class _ConflictBar extends StatelessWidget {
  const _ConflictBar({required this.conflict});

  final ProjectConflict conflict;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      color: scheme.tertiaryContainer,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          Icon(Icons.merge_type, size: 18, color: scheme.onTertiaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '"${conflict.local.title}" changed here and on GitHub.',
              style: TextStyle(color: scheme.onTertiaryContainer, fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: () => ConflictDialog.show(context, conflict),
            child: const Text('Resolve'),
          ),
        ],
      ),
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
      padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
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
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'This device only. Connect a GitHub repo to sync.',
              style: TextStyle(color: scheme.onSecondaryContainer, fontSize: 13),
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

class _NoProjects extends StatelessWidget {
  const _NoProjects();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.checklist_rtl,
              size: 48,
              color: theme.colorScheme.outlineVariant,
            ),
            const SizedBox(height: 12),
            Text('No projects yet', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              'Each project is one markdown file in your repo.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoProjectSelected extends StatelessWidget {
  const _NoProjectSelected();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Text(
        'Create a project to get started.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

Future<void> createProject(BuildContext context, {bool openAfter = false}) async {
  final title = await TextPromptDialog.show(
    context,
    title: 'New project',
    hintText: 'Project name',
  );
  if (title == null || !context.mounted) return;

  final state = context.read<AppState>();
  final project = await state.createProject(title);
  state.select(project.slug);
  if (!openAfter || !context.mounted) return;

  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => ChecklistView(slug: project.slug)),
  );
}

Future<void> confirmDeleteProject(BuildContext context, Project project) async {
  final state = context.read<AppState>();

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
