import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../models/project.dart';
import '../models/sidebar_layout.dart';
import '../markdown/feed_days.dart';
import '../state/app_state.dart';
import 'checklist_view.dart';
import 'context_menu.dart';
import 'note_editor.dart';
import 'search_screen.dart';
import 'shared_notebooks.dart';
import 'starred_screen.dart';
import 'sync_status.dart';
import 'update_banner.dart';
import 'shortcuts_sheet.dart';
import 'settings_screen.dart';
import 'text_prompt.dart';
import 'touch_input.dart';

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
        // The same activators the sheet documents, so the two cannot
        // disagree about which keys open it.
        for (final activator in shortcutsSheetActivators)
          activator: () => showShortcutsSheet(context),
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

class _TwoPaneLayout extends StatefulWidget {
  const _TwoPaneLayout();

  @override
  State<_TwoPaneLayout> createState() => _TwoPaneLayoutState();
}

class _TwoPaneLayoutState extends State<_TwoPaneLayout> {
  final List<String> _tabs = [];
  final List<String> _rightTabs = [];
  final Map<int, NoteTarget?> _paneNotes = {};
  String? _active;
  String? _rightActive;
  String? _lastSelected;
  int _focused = 0;
  bool _split = false;
  double _splitFraction = .5;
  bool _sidebarCollapsed = false;
  bool _openedInitialProject = false;

  List<String> _forPane(int pane) => pane == 0 ? _tabs : _rightTabs;
  String? _activeFor(int pane) => pane == 0 ? _active : _rightActive;

  void _setActive(int pane, String? slug) {
    if (pane == 0) {
      _active = slug;
    } else {
      _rightActive = slug;
    }
  }

  void _show(AppState state, int pane, String slug, {bool newTab = false}) {
    if (state.projectBySlug(slug) == null) return;
    final tabs = _forPane(pane);
    setState(() {
      if (_activeFor(pane) != slug) _paneNotes.remove(pane);
      if (!tabs.contains(slug)) {
        if (newTab || tabs.isEmpty || _activeFor(pane) == null) {
          tabs.add(slug);
        } else {
          final at = tabs.indexOf(_activeFor(pane)!);
          if (at < 0) {
            tabs.add(slug);
          } else {
            tabs[at] = slug;
          }
        }
      }
      _setActive(pane, slug);
      _focused = pane;
    });
    _lastSelected = slug;
    state.select(slug);
  }

  void _closeTab(AppState state, int pane, String slug) {
    final tabs = _forPane(pane);
    final at = tabs.indexOf(slug);
    if (at < 0) return;
    setState(() {
      tabs.removeAt(at);
      if (_activeFor(pane) == slug) {
        _setActive(pane, tabs.isEmpty ? null : tabs[at.clamp(0, tabs.length - 1)]);
      }
    });
    if (_focused == pane) {
      _lastSelected = _activeFor(pane);
      state.select(_lastSelected);
    }
  }

  void _focus(AppState state, int pane) {
    if (_focused == pane) return;
    setState(() => _focused = pane);
    _lastSelected = _activeFor(pane);
    state.select(_lastSelected);
  }

  void _toggleSplit(AppState state) {
    setState(() {
      _split = !_split;
      if (_split) {
        _rightActive = _active;
        _rightTabs
          ..clear()
          ..addAll([if (_active != null) _active!]);
      } else {
        _rightTabs.clear();
        _rightActive = null;
        _focused = 0;
      }
    });
    _lastSelected = _activeFor(_focused);
    state.select(_lastSelected);
  }

  Widget _pane(AppState state, ThemeData theme, int pane,
      {double? width}) {
    final active = _activeFor(pane);
    final project = state.projectBySlug(active ?? '');
    final content = DragTarget<NoteTarget>(
      onWillAcceptWithDetails: (details) =>
          state.projectBySlug(details.data.slug) != null,
      onAcceptWithDetails: (details) {
        _show(state, pane, details.data.slug);
        setState(() => _paneNotes[pane] = details.data);
      },
      builder: (context, candidates, rejected) => Listener(
      onPointerDown: (_) => _focus(state, pane),
      child: DecoratedBox(
        decoration: BoxDecoration(border: pane == 1
            ? Border(left: BorderSide(color: theme.colorScheme.outlineVariant))
            : null),
        child: Column(children: [
          _ProjectTabs(
            projects: [
              for (final slug in _forPane(pane))
                if (state.projectBySlug(slug) case final found?) found,
            ],
            available: state.projects,
            selectedSlug: active,
            onOpen: (slug) => _show(state, pane, slug, newTab: true),
            onClose: (slug) => _closeTab(state, pane, slug),
            onToggleSidebar: pane == 0 ? () => setState(
                () => _sidebarCollapsed = !_sidebarCollapsed) : null,
            sidebarCollapsed: _sidebarCollapsed,
            onToggleSplit: () => _toggleSplit(state),
            split: _split,
          ),
          Expanded(child: project == null
              ? const _NoProjectSelected()
              : PaneNoteScope(
                  onOpen: (slug, index) => setState(() {
                    _paneNotes[pane] = NoteTarget(slug, index);
                  }),
                  child: _DetailPane(
                    project: project,
                    note: _paneNotes[pane] ??
                        (_focused == pane ? state.openNote : null),
                    onClose: () => setState(() {
                      _paneNotes.remove(pane);
                      if (_focused == pane) state.hideNote();
                    }),
                  ),
                )),
        ]),
      ),
    ));
    return width == null ? Expanded(child: content) : SizedBox(width: width, child: content);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    _tabs.removeWhere((slug) => state.projectBySlug(slug) == null);
    _rightTabs.removeWhere((slug) => state.projectBySlug(slug) == null);
    if (!_openedInitialProject && state.projects.isNotEmpty) {
      _openedInitialProject = true;
      _active = state.projectBySlug(state.selectedSlug ?? '')?.slug ??
          state.projects.first.slug;
      _tabs.add(_active!);
      _lastSelected = state.selectedSlug;
    }
    if (state.selectedSlug != _lastSelected &&
        state.projectBySlug(state.selectedSlug ?? '') != null) {
      final slug = state.selectedSlug!;
      final tabs = _forPane(_focused);
      if (!tabs.contains(slug)) {
        final at = tabs.indexOf(_activeFor(_focused) ?? '');
        if (at < 0) {
          tabs.add(slug);
        } else {
          tabs[at] = slug;
        }
      }
      _setActive(_focused, slug);
      _lastSelected = slug;
    }

    return Scaffold(
      body: LayoutBuilder(builder: (context, constraints) {
        final contentWidth = constraints.maxWidth - (_sidebarCollapsed ? 0 : 280);
        final paneWidth = (contentWidth - 8).clamp(1.0, double.infinity).toDouble();
        return Row(
        children: [
          if (!_sidebarCollapsed) SizedBox(
            width: 280,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                border: Border(
                  right: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
              ),
              child: ProjectSidebar(
                selectedSlug: _activeFor(_focused),
                onSelect: (slug) => _show(state, _focused, slug),
                onOpenInNewTab: (slug) => _show(state, _focused, slug,
                    newTab: true),
              ),
            ),
          ),
          _pane(state, theme, 0,
              width: _split ? paneWidth * _splitFraction : null),
          if (_split) MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (details) => setState(() {
                _splitFraction = (_splitFraction + details.delta.dx / paneWidth)
                    .clamp(.2, .8).toDouble();
              }),
              child: Container(width: 8, color: theme.colorScheme.outlineVariant),
            ),
          ),
          if (_split) _pane(state, theme, 1,
              width: paneWidth * (1 - _splitFraction)),
        ],
      );
      }),
    );
  }
}

/// Routes note openings to the desktop pane where the action happened.
class PaneNoteScope extends InheritedWidget {
  const PaneNoteScope({super.key, required this.onOpen, required super.child});

  final void Function(String slug, int index) onOpen;

  static PaneNoteScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PaneNoteScope>();

  @override
  bool updateShouldNotify(PaneNoteScope oldWidget) => onOpen != oldWidget.onOpen;
}

/// Projects stay open across sidebar switches. The sidebar's existing drag
/// gesture can drop a project anywhere on this strip to open its tab.
class _ProjectTabs extends StatelessWidget {
  const _ProjectTabs({required this.projects, required this.available,
    required this.selectedSlug, required this.onOpen, required this.onClose,
    required this.onToggleSidebar, required this.sidebarCollapsed,
    required this.onToggleSplit, required this.split});

  final List<Project> projects;
  final List<Project> available;
  final String? selectedSlug;
  final ValueChanged<String> onOpen;
  final ValueChanged<String> onClose;
  final VoidCallback? onToggleSidebar;
  final bool sidebarCollapsed;
  final VoidCallback onToggleSplit;
  final bool split;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) =>
          available.any((project) => project.slug == details.data),
      onAcceptWithDetails: (details) => onOpen(details.data),
      builder: (context, candidates, rejected) => Container(
        height: 44,
        decoration: BoxDecoration(
          color: candidates.isNotEmpty
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerLow,
          border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
        ),
        child: Row(children: [
          if (onToggleSidebar != null)
            IconButton(
              tooltip: sidebarCollapsed ? 'Show projects' : 'Hide projects',
              icon: Icon(sidebarCollapsed ? Icons.menu_open : Icons.menu),
              onPressed: onToggleSidebar,
            ),
          Expanded(child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final project in projects)
                SizedBox(
                  width: 184,
                  child: Material(
                    color: project.slug == selectedSlug
                        ? theme.colorScheme.surface
                        : Colors.transparent,
                    child: Row(children: [
                      Expanded(child: InkWell(
                        onTap: () => onOpen(project.slug),
                        child: Padding(
                          padding: const EdgeInsets.only(left: 14),
                          child: Text(project.title, maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                      )),
                      IconButton(
                        tooltip: 'Close ${project.title} tab',
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () => onClose(project.slug),
                      ),
                    ]),
                  ),
                ),
            ],
          )),
          PopupMenuButton<String>(
            tooltip: 'Open project tab',
            icon: const Icon(Icons.add, size: 20),
            onSelected: onOpen,
            itemBuilder: (_) => [
              for (final project in available)
                PopupMenuItem(value: project.slug, child: Text(project.title)),
            ],
          ),
          IconButton(
            tooltip: split ? 'Close split view' : 'Split view right',
            icon: Icon(split ? Icons.vertical_split : Icons.view_column_outlined,
                size: 20),
            onPressed: onToggleSplit,
          ),
        ]),
      ),
    );
  }
}

/// The right-hand side: a project's checklist, or one item's notes.
///
/// A note edited here keeps the sidebar, which is the point — on a phone the
/// editor is a screen of its own, because there is no sidebar to keep.
class _DetailPane extends StatelessWidget {
  const _DetailPane({required this.project, required this.note,
    required this.onClose});

  final Project project;
  final NoteTarget? note;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final target = note;
    // An index only means something against the list it came from. Anything
    // that shortens the list closes the note, but a sync landing another
    // device's edit can still take the item away underneath us.
    if (target != null &&
        target.slug == project.slug &&
        target.index < project.items.length) {
      final item = project.items[target.index];

      return NoteEditor(
        // Keyed by the item so opening another note builds a fresh editor
        // rather than handing this one the last note's blocks.
        key: ValueKey('note-${project.slug}-${target.index}'),
        slug: project.slug,
        index: target.index,
        title: item.text,
        initialNotes: item.notes,
        onClose: onClose,
      );
    }

    return Column(
      children: [
        _DetailHeader(project: project),
        Expanded(
          child: ChecklistView(
            // Keyed so switching project rebuilds the view's own state
            // rather than reusing the last one's.
            key: ValueKey(project.slug),
            slug: project.slug,
            showAppBar: false,
          ),
        ),
      ],
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
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
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
            tooltip: 'Archive completed',
            icon: const Icon(Icons.inventory_2_outlined),
            onPressed: () async {
              final problem = await context.read<AppState>().archiveCompleted(
                project.slug,
              );
              if (problem == null || !context.mounted) return;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(problem)));
            },
          ),
        ],
      ),
    );
  }
}

/// The phone's project switcher, available from every project screen.
class MobileProjectDrawer extends StatelessWidget {
  const MobileProjectDrawer({super.key, this.selectedSlug});

  final String? selectedSlug;

  @override
  Widget build(BuildContext context) => Drawer(
    child: SafeArea(
      child: ProjectSidebar(
        selectedSlug: selectedSlug,
        drawerMode: true,
        onSelect: (slug) {
          final navigator = Navigator.of(context);
          // Closing the drawer restores the current route before changing the
          // project, so a swipe or Back never leaves a drawer behind.
          navigator.pop();
          if (slug == selectedSlug) return;
          final route = MaterialPageRoute<void>(
            builder: (_) => ChecklistView(slug: slug),
          );
          if (selectedSlug == null) {
            navigator.push(route);
          } else {
            navigator.pushReplacement(route);
          }
        },
      ),
    ),
  );
}

class _SinglePaneLayout extends StatelessWidget {
  const _SinglePaneLayout();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: const MobileProjectDrawer(),
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [Text('ActionNotes'), AppVersionLabel()],
        ),
        actions: [
          IconButton(
            tooltip: 'Daily note',
            icon: const Icon(Icons.today_outlined),
            onPressed: () => openDailyNote(context, openAfter: true),
          ),
          const _SearchAction(), const _SyncAction(), const _SettingsAction(),
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
    this.drawerMode = false,
    this.onSelect,
    this.onOpenInNewTab,
  });

  final String? selectedSlug;

  /// True on a phone, where tapping a project opens it as a new screen.
  final bool pushOnTap;
  final bool drawerMode;
  final ValueChanged<String>? onSelect;
  final ValueChanged<String>? onOpenInNewTab;

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

    final filtering = _filter.text.trim().isNotEmpty;
    final projects = _visible(state.projects);

    return Column(
      children: [
        if (!widget.pushOnTap || widget.drawerMode) ...[
          const _SidebarHeader(),
          _SidebarSearch(
            controller: _filter,
            focusNode: _filterFocus,
            onChanged: () => setState(() {}),
          ),
          const _ProjectsLabel(),
        ],
        if (state.message != null) _MessageBar(message: state.message!),
        if (!state.isConfigured) const _SetupPrompt(),
        Expanded(
          child: state.projects.isEmpty
              ? const _NoProjects()
              : projects.isEmpty
              ? const _NoMatches()
              : RefreshIndicator(
                  onRefresh: state.sync,
                  child: _ProjectList(
                    // While something is typed, the groups are set aside and
                    // every match is shown together: you are looking for a
                    // project, not for where you filed it.
                    filtered: filtering ? projects : null,
                    selectedSlug: widget.selectedSlug,
                    pushOnTap: widget.pushOnTap || widget.drawerMode,
                    onSelect: widget.onSelect,
                    onOpenInNewTab: widget.onOpenInNewTab,
                  ),
                ),
        ),
        if (!widget.pushOnTap || widget.drawerMode) const _SidebarFooter(),
      ],
    );
  }
}

/// The project list: the ones in no group first, then each group under its
/// own heading.
///
/// Ungrouped first because a list you have not filed is one you are still
/// using, and burying it under the headings of things you have finished
/// organising would be the wrong way round.
class _ProjectList extends StatelessWidget {
  const _ProjectList({
    required this.filtered,
    required this.selectedSlug,
    required this.pushOnTap,
    this.onSelect,
    this.onOpenInNewTab,
  });

  /// The matches, when something is typed in the box — in which case the
  /// groups are set aside entirely. Null when nothing is being searched for.
  final List<Project>? filtered;
  final String? selectedSlug;
  final bool pushOnTap;
  final ValueChanged<String>? onSelect;
  final ValueChanged<String>? onOpenInNewTab;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final padding = EdgeInsets.only(bottom: pushOnTap ? 96 : 12);

    final matches = filtered;
    if (matches != null) {
      return ListView.builder(
        padding: padding,
        itemCount: matches.length,
        itemBuilder: (context, index) => _ProjectTile(
          project: matches[index],
          selected: matches[index].slug == selectedSlug,
          pushOnTap: pushOnTap,
          onSelect: onSelect,
          onOpenInNewTab: onOpenInNewTab,
        ),
      );
    }

    final loose = state.looseProjects;

    return ListView(
      padding: padding,
      children: [
        for (var index = 0; index < loose.length; index++)
          _DropBefore(
            group: null,
            at: index,
            child: _ProjectTile(
              project: loose[index],
              selected: loose[index].slug == selectedSlug,
              pushOnTap: pushOnTap,
              onSelect: onSelect,
              onOpenInNewTab: onOpenInNewTab,
            ),
          ),
        // The end of the ungrouped run, so something can be dragged out of a
        // group and dropped below everything rather than only above
        // something.
        _DropBefore(group: null, at: loose.length, tall: loose.isEmpty),
        for (final group in state.sidebar.groups) ...[
          _GroupHeading(group: group),
          if (!group.collapsed)
            for (var index = 0; index < state.projectsIn(group).length; index++)
              _DropBefore(
                group: group.name,
                at: index,
                child: _ProjectTile(
                  project: state.projectsIn(group)[index],
                  selected: state.projectsIn(group)[index].slug == selectedSlug,
                  pushOnTap: pushOnTap,
                  onSelect: onSelect,
                  onOpenInNewTab: onOpenInNewTab,
                ),
              ),
          if (!group.collapsed)
            _DropBefore(
              group: group.name,
              at: state.projectsIn(group).length,
              tall: state.projectsIn(group).isEmpty,
            ),
        ],
      ],
    );
  }
}

/// Puts a project in a group from the menu, for a phone and for anybody who
/// would rather not drag things about.
Future<void> _moveToGroup(BuildContext context, Project project) async {
  final state = context.read<AppState>();
  final groups = state.sidebar.groups;
  final current = state.groupOf(project.slug)?.name;

  final chosen = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text('Where does "${project.title}" go?'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop('~none'),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.list),
            title: const Text('No group'),
            trailing: current == null ? const Icon(Icons.check) : null,
          ),
        ),
        for (final group in groups)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(group.name),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.folder_outlined,
                color: groupColours[group.colour],
              ),
              title: Text(group.name),
              trailing: current == group.name ? const Icon(Icons.check) : null,
            ),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop('~new'),
          child: const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.create_new_folder_outlined),
            title: Text('New group…'),
          ),
        ),
      ],
    ),
  );

  if (chosen == null || !context.mounted) return;

  if (chosen == '~new') {
    final made = await newGroup(context);
    if (made == null) return;
    await state.placeProject(project.slug, group: made);
    return;
  }

  await state.placeProject(
    project.slug,
    group: chosen == '~none' ? null : chosen,
  );
}

/// "Projects", with a way to make a group beside it.
class _ProjectsLabel extends StatelessWidget {
  const _ProjectsLabel();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(child: _SidebarLabel('Projects')),
        IconButton(
          tooltip: 'New group',
          icon: const Icon(Icons.create_new_folder_outlined, size: 16),
          visualDensity: VisualDensity.compact,
          onPressed: () => newGroup(context),
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}

/// Asks for a name and makes a group. Shared by the sidebar's own button and
/// by a project's "Move to group" when there is nowhere to move it yet.
Future<String?> newGroup(BuildContext context) async {
  final state = context.read<AppState>();
  final name = await TextPromptDialog.show(
    context,
    title: 'New group',
    hintText: 'Work, Home, Someday…',
    confirmLabel: 'Make it',
  );
  if (name == null) return null;

  if (!await state.addGroup(name)) {
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('There is already a group called that.')),
    );
    return null;
  }
  return name.trim();
}

/// The colours a group can be given.
///
/// Named rather than hex, so a group keeps its colour when the theme changes
/// and reads as something in the file. Drawn from the scheme, so they sit
/// together in light and dark alike.
const groupColours = <String, Color>{
  '': Color(0x00000000),
  'red': Color(0xFFE57373),
  'orange': Color(0xFFFFB74D),
  'green': Color(0xFF81C784),
  'blue': Color(0xFF64B5F6),
  'purple': Color(0xFFBA68C8),
  'pink': Color(0xFFF06292),
};

/// A group's heading: its name, how many are in it, and a colour down the
/// side so two groups can be told apart without reading.
class _GroupHeading extends StatefulWidget {
  const _GroupHeading({required this.group});

  final ProjectGroup group;

  @override
  State<_GroupHeading> createState() => _GroupHeadingState();
}

class _GroupHeadingState extends State<_GroupHeading> {
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<AppState>();
    final colour = groupColours[widget.group.colour] ?? Colors.transparent;
    final count = state.projectsIn(widget.group).length;

    return DragTarget<String>(
      // Dropping on the heading puts it in the group, wherever in the group
      // it lands — which is what aiming at a name rather than a gap means.
      onWillAcceptWithDetails: (_) {
        setState(() => _over = true);
        return true;
      },
      onLeave: (_) => setState(() => _over = false),
      onAcceptWithDetails: (details) {
        setState(() => _over = false);
        state.placeProject(details.data, group: widget.group.name);
      },
      builder: (context, candidate, rejected) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 2),
        child: Material(
          color: _over
              ? theme.colorScheme.primary.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => state.toggleGroup(widget.group.name),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                children: [
                  Icon(
                    widget.group.collapsed
                        ? Icons.chevron_right
                        : Icons.expand_more,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  if (widget.group.colour.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Container(width: 3, height: 14, color: colour),
                  ],
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      widget.group.name,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Text(
                    '$count',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  _GroupMenu(group: widget.group),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GroupMenu extends StatelessWidget {
  const _GroupMenu({required this.group});

  final ProjectGroup group;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();

    return PopupMenuButton<String>(
      tooltip: 'Group actions',
      icon: const Icon(Icons.more_horiz, size: 16),
      padding: EdgeInsets.zero,
      iconSize: 16,
      onSelected: (value) async {
        switch (value) {
          case 'rename':
            final name = await TextPromptDialog.show(
              context,
              title: 'Rename group',
              initialValue: group.name,
            );
            if (name == null || !context.mounted) return;
            if (!await state.renameGroup(group.name, name) && context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('There is already a group called that.'),
                ),
              );
            }
          case 'remove':
            await state.removeGroup(group.name);
          default:
            await state.setGroupColour(group.name, value);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'rename', child: Text('Rename')),
        // Said as what it does. Nothing in it is deleted — a group is a way
        // of looking at a list, not a place the lists are kept.
        const PopupMenuItem(value: 'remove', child: Text('Ungroup these')),
        const PopupMenuDivider(),
        for (final entry in groupColours.entries)
          PopupMenuItem(
            value: entry.key,
            child: Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: entry.key.isEmpty ? Colors.transparent : entry.value,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(entry.key.isEmpty ? 'No colour' : entry.key),
              ],
            ),
          ),
      ],
    );
  }
}

/// A place a dragged project can be let go of: the gap above a row.
///
/// A thin line rather than a whole row, so the list does not jump about while
/// something is being carried over it — the line lighting up is enough to say
/// where it would land.
class _DropBefore extends StatefulWidget {
  const _DropBefore({
    required this.group,
    required this.at,
    this.child,
    this.tall = false,
  });

  final String? group;
  final int at;
  final Widget? child;

  /// An empty group, or an empty ungrouped run, needs something big enough to
  /// aim at.
  final bool tall;

  @override
  State<_DropBefore> createState() => _DropBeforeState();
}

class _DropBeforeState extends State<_DropBefore> {
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DragTarget<String>(
      onWillAcceptWithDetails: (_) => true,
      onMove: (details) {
        if (!_over) setState(() => _over = true);
      },
      onLeave: (_) => setState(() => _over = false),
      onAcceptWithDetails: (details) {
        setState(() => _over = false);
        context.read<AppState>().placeProject(
          details.data,
          group: widget.group,
          at: widget.at,
        );
      },
      builder: (context, candidate, rejected) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: _over ? 10 : (widget.tall ? 28 : 6),
            margin: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: _over
                  ? theme.colorScheme.primary
                  : (widget.tall
                        ? theme.colorScheme.outlineVariant.withValues(alpha: 0.25)
                        : Colors.transparent),
              borderRadius: BorderRadius.circular(3),
            ),
            alignment: Alignment.center,
            child: widget.tall && !_over
                ? Text('Drop a project here', style: theme.textTheme.labelSmall)
                : null,
          ),
          if (widget.child != null) widget.child!,
        ],
      ),
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
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
          const _StarredAction(),
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
                backgroundColor: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
        ),
        if (MediaQuery.sizeOf(context).width >= HomeShell.sidebarBreakpoint)
          TextButton.icon(
            onPressed: () => openDailyNote(context),
            icon: const Icon(Icons.today_outlined, size: 18),
            label: const Text('Daily note'),
          ),
        const UpdateBanner(),
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Align(alignment: Alignment.centerLeft, child: SyncStatus()),
        ),
        // Settings sits at the foot of the sidebar rather than among the
        // icons at the top: it is the thing you open least.
        InkWell(
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
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
                // A phone has no ? key to press, so the sheet needs a way in
                // that is not a shortcut.
                IconButton(
                  tooltip: 'Keyboard shortcuts',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.keyboard_outlined, size: 18),
                  onPressed: () => showShortcutsSheet(context),
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
    this.onSelect,
    this.onOpenInNewTab,
  });

  final Project project;
  final bool selected;
  final bool pushOnTap;
  final ValueChanged<String>? onSelect;
  final ValueChanged<String>? onOpenInNewTab;

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

    final actions = [
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
      if (project.isShared)
        ContextMenuAction(
          label: 'Stop sharing',
          icon: Icons.folder_off_outlined,
          onSelected: () => ShareProjectDialog.stopSharing(context, project),
        )
      else
        ContextMenuAction(
          label: 'Share\u2026',
          icon: Icons.folder_shared_outlined,
          onSelected: () => ShareProjectDialog.show(context, project),
        ),
      ContextMenuAction(
        label: 'Move to group…',
        icon: Icons.folder_outlined,
        onSelected: () => _moveToGroup(context, project),
      ),
      if (onOpenInNewTab != null)
        ContextMenuAction(
          label: 'New tab',
          icon: Icons.tab_outlined,
          onSelected: () => onOpenInNewTab!(project.slug),
        ),
      ContextMenuAction(
        label: 'Delete',
        icon: Icons.delete_outline,
        destructive: true,
        onSelected: () => confirmDeleteProject(context, project),
      ),
    ];

    return ItemContextMenu(
      actions: actions,
      // A long press picks the row up to move it, so it cannot also open the
      // menu — one gesture cannot do both. The menu is on a button, which is
      // the same bargain the checklist rows made.
      longPress: false,
      child: (TouchInput.isPrimary
          ? LongPressDraggable<String>(
              data: project.slug,
              dragAnchorStrategy: pointerDragAnchorStrategy,
              feedback: _dragFeedback(theme),
              childWhenDragging: Opacity(opacity: 0.35,
                  child: _tile(context, theme, titleStyle, open, actions)),
              child: _tile(context, theme, titleStyle, open, actions),
            )
          : Draggable<String>(
        data: project.slug,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        // What is being carried, small and under the finger, rather than a
        // full-width row covering the list it is being dropped into.
        feedback: _dragFeedback(theme),
        childWhenDragging: Opacity(
          opacity: 0.35,
          child: _tile(context, theme, titleStyle, open, actions),
        ),
        child: _tile(context, theme, titleStyle, open, actions),
      )),
    );
  }

  Widget _dragFeedback(ThemeData theme) => Material(
    elevation: 4,
    borderRadius: BorderRadius.circular(6),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Text(project.title, style: theme.textTheme.bodyMedium),
    ),
  );

  Widget _tile(
    BuildContext context,
    ThemeData theme,
    TextStyle? titleStyle,
    int open,
    List<ContextMenuAction> actions,
  ) {
    final state = context.read<AppState>();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.13)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            if (onSelect != null) {
              onSelect!(project.slug);
            } else if (pushOnTap) {
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
                  height: pushOnTap ? 24 : 22,
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
                    pushOnTap ? 4 : 3,
                    10,
                    pushOnTap ? 4 : 3,
                  ),
                  child: Row(
                    children: [
                      Tooltip(
                        message: project.mode == ProjectMode.notes
                            ? 'Notes project'
                            : project.mode == ProjectMode.feed
                                ? 'Timeline project'
                                : project.items.isEmpty &&
                                        project.blocks.isNotEmpty &&
                                        project.blocks.every((block) =>
                                            state.isCanvas(project.slug, block.title))
                                    ? 'Canvas project'
                                    : 'Tasks project',
                        child: Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: Icon(
                            project.mode == ProjectMode.notes
                                ? Icons.notes_outlined
                                : project.mode == ProjectMode.feed
                                    ? Icons.timeline
                                    : project.items.isEmpty &&
                                            project.blocks.isNotEmpty &&
                                            project.blocks.every((block) =>
                                                state.isCanvas(project.slug, block.title))
                                        ? Icons.dashboard_outlined
                                        : Icons.check_box_outlined,
                            size: 19,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Flexible(
                        fit: FlexFit.loose,
                        child: Text(
                          project.title,
                          overflow: TextOverflow.ellipsis,
                          style: titleStyle,
                        ),
                      ),
                      if (project.isShared)
                        Padding(
                          padding: const EdgeInsets.only(left: 4, right: 6),
                          child: Tooltip(
                            message: 'In ${state.sourceOf(project.slug).name}',
                            child: Icon(
                              Icons.folder_shared_outlined,
                              size: 14,
                              color: theme.colorScheme.primary,
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
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest
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
                      ItemMenuButton(
                        actions: actions,
                        tooltip: 'Project actions',
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StarredAction extends StatelessWidget {
  const _StarredAction();

  @override
  Widget build(BuildContext context) {
    final count = starredAcross(context.watch<AppState>().projects).length;

    return IconButton(
      tooltip: 'Everything starred',
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        child: const Icon(Icons.star_border),
      ),
      onPressed: () => StarredScreen.open(context),
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
      onPressed: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
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
              style: TextStyle(
                color: scheme.onSecondaryContainer,
                fontSize: 13,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
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

Future<void> createProject(
  BuildContext context, {
  bool openAfter = false,
}) async {
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

  await Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => ChecklistView(slug: project.slug)));
}

Future<void> openDailyNote(BuildContext context, {bool openAfter = false}) async {
  final state = context.read<AppState>();
  var project = state.projectBySlug('daily-note');
  project ??= await state.createProject('Daily note');
  if (project.mode != ProjectMode.feed) {
    await state.setMode(project.slug, ProjectMode.feed);
  }
  await state.addBlock(project.slug, FeedDays.titleFor(DateTime.now()));
  state.select(project.slug);
  if (openAfter && context.mounted) {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ChecklistView(slug: project!.slug),
    ));
  }
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
