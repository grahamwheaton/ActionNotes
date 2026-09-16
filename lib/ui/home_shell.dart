import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../models/project.dart';
import '../state/app_state.dart';
import '../storage/sync_service.dart';
import 'checklist_view.dart';
import 'conflict_dialog.dart';
import 'context_menu.dart';
import 'search_screen.dart';
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
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            SearchScreen.open(context),
      },
      child: LayoutBuilder(
        builder: (context, constraints) =>
            constraints.maxWidth >= sidebarBreakpoint
                ? const _TwoPaneLayout()
                : const _SinglePaneLayout(),
      ),
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
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [Text('ActionNotes'), AppVersionLabel()],
        ),
        actions: const [
          _SearchAction(),
          _SyncAction(),
          _SettingsAction(),
        ],
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
class ProjectSidebar extends StatefulWidget {
  const ProjectSidebar({
    super.key,
    required this.selectedSlug,
    this.pushOnTap = false,
  });

  final String? selectedSlug;

  /// True on a phone, where tapping a project opens it as a new screen.
  final bool pushOnTap;

  @override
  State<ProjectSidebar> createState() => _ProjectSidebarState();
}

class _ProjectSidebarState extends State<ProjectSidebar> {
  final _filter = TextEditingController();
  final _filterFocus = FocusNode();

  @override
  void dispose() {
    _filter.dispose();
    _filterFocus.dispose();
    super.dispose();
  }

  /// Narrows the list as you type. Only titles: searching inside items and
  /// notes is what the full search screen is for, and mixing the two would
  /// make this box answer a question it did not ask.
  List<Project> _visible(List<Project> projects) {
    final query = _filter.text.trim().toLowerCase();
    if (query.isEmpty) return projects;
    return [
      for (final project in projects)
        if (project.title.toLowerCase().contains(query)) project,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    if (state.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final projects = _visible(state.projects);

    return Column(
      children: [
        if (!widget.pushOnTap) ...[
          const _SidebarHeader(),
          _SidebarSearch(
            controller: _filter,
            focusNode: _filterFocus,
            onChanged: () => setState(() {}),
          ),
          const _SidebarLabel('Projects'),
        ],
        for (final conflict in state.conflicts)
          _ConflictBar(conflict: conflict),
        if (state.message != null) _MessageBar(message: state.message!),
        if (!state.isConfigured) const _SetupPrompt(),
        Expanded(
          child: state.projects.isEmpty
              ? const _NoProjects()
              : projects.isEmpty
                  ? const _NoMatches()
                  : RefreshIndicator(
                      onRefresh: state.sync,
                      child: ListView.builder(
                        padding:
                            EdgeInsets.only(bottom: widget.pushOnTap ? 96 : 12),
                        itemCount: projects.length,
                        itemBuilder: (context, index) => _ProjectTile(
                          project: projects[index],
                          selected: projects[index].slug == widget.selectedSlug,
                          pushOnTap: widget.pushOnTap,
                        ),
                      ),
                    ),
        ),
        if (!widget.pushOnTap) const _SidebarFooter(),
      ],
    );
  }
}

/// A quiet section heading, in the shape Obsidian's sidebar uses: small,
/// spaced, and not competing with the names under it.
class _SidebarLabel extends StatelessWidget {
  const _SidebarLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
        child: Text(
          text.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            letterSpacing: 0.8,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _SidebarSearch extends StatelessWidget {
  const _SidebarSearch({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        onChanged: (_) => onChanged(),
        style: theme.textTheme.bodyMedium,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search projects...',
          hintStyle: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          prefixIcon: Icon(
            Icons.search,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 36),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          // Everything beyond the title lives in the full search screen, and
          // the shortcut that opens it is worth saying out loud.
          suffixIcon: Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Tooltip(
              message: 'Search',
              child: GestureDetector(
              onTap: () => SearchScreen.open(context),
              child: Center(
                widthFactor: 1,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Ctrl K',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NoMatches extends StatelessWidget {
  const _NoMatches();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          'No project by that name.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _SidebarHeader extends StatelessWidget {
  const _SidebarHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 10, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'ActionNotes',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
          ),
          // Search and settings have their own places below now; syncing is
          // the one thing you reach for from anywhere.
          const _SyncAction(),
        ],
      ),
    );
  }
}

/// The running version, read from the package rather than a second constant
/// that could drift from pubspec. Shows nothing until it resolves, and stays
/// empty if it cannot be read, so it never blocks the header.
class AppVersionLabel extends StatefulWidget {
  const AppVersionLabel({super.key});

  @override
  State<AppVersionLabel> createState() => _AppVersionLabelState();
}

class _AppVersionLabelState extends State<AppVersionLabel> {
  String? _version;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _version = info.version);
    } catch (_) {
      // Not worth surfacing; the label simply stays absent.
    }
  }

  @override
  Widget build(BuildContext context) {
    final version = _version;
    if (version == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Text(
      'v$version',
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _SidebarFooter extends StatelessWidget {
  const _SidebarFooter();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          child: SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              onPressed: () => createProject(context),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New project'),
              style: TextButton.styleFrom(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                backgroundColor:
                    theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
        ),
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
        // Settings sits at the foot of the sidebar rather than among the
        // icons at the top: it is the thing you open least.
        InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 16, 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Settings',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const AppVersionLabel(),
              ],
            ),
          ),
        ),
      ],
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

    // The phone list is the whole screen, so it gets a size to match the
    // apps it sits beside; the desktop sidebar stays compact.
    final titleStyle = pushOnTap
        ? theme.textTheme.titleMedium?.copyWith(
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          )
        : theme.textTheme.bodyMedium?.copyWith(
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          );

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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        child: Material(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.13)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
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
            child: Row(
              children: [
                // A bar down the selected row, the way a vault's file list
                // marks the open note. Always laid out, so the titles line up
                // whether or not a row is selected.
                Container(
                  width: 2,
                  height: pushOnTap ? 40 : 30,
                  decoration: BoxDecoration(
                    color: selected
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      12,
                      pushOnTap ? 14 : 7,
                      10,
                      pushOnTap ? 14 : 7,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            project.title,
                            overflow: TextOverflow.ellipsis,
                            style: titleStyle,
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
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: theme
                                  .colorScheme.surfaceContainerHighest
                                  .withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '$open',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchAction extends StatelessWidget {
  const _SearchAction();

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Search',
      icon: const Icon(Icons.search),
      onPressed: () => SearchScreen.open(context),
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
