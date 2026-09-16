import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/project.dart';
import '../state/app_state.dart';

/// Picks a project to link to. Filters as you type, the way Obsidian's link
/// suggester does.
class ProjectPicker extends StatefulWidget {
  const ProjectPicker({super.key, this.excludeSlug});

  /// The project being edited, which there is no point linking to itself.
  final String? excludeSlug;

  static Future<Project?> show(
    BuildContext context, {
    String? excludeSlug,
  }) {
    return showDialog<Project>(
      context: context,
      builder: (_) => ProjectPicker(excludeSlug: excludeSlug),
    );
  }

  @override
  State<ProjectPicker> createState() => _ProjectPickerState();
}

class _ProjectPickerState extends State<ProjectPicker> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _controller.text.trim().toLowerCase();

    final matches = [
      for (final project in context.watch<AppState>().projects)
        if (project.slug != widget.excludeSlug &&
            (query.isEmpty || project.title.toLowerCase().contains(query)))
          project,
    ];

    return AlertDialog(
      title: const Text('Link to project'),
      content: SizedBox(
        width: 420,
        height: 360,
        child: Column(
          children: [
            TextField(
              controller: _controller,
              focusNode: _focus,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Search projects'),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (matches.isNotEmpty) Navigator.of(context).pop(matches.first);
              },
            ),
            const SizedBox(height: 12),
            Expanded(
              child: matches.isEmpty
                  ? Center(
                      child: Text(
                        query.isEmpty
                            ? 'No other projects yet.'
                            : 'Nothing matches "$query".',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: matches.length,
                      itemBuilder: (context, index) {
                        final project = matches[index];
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.checklist, size: 18),
                          title: Text(project.title),
                          subtitle: Text(
                            '${project.slug}.md',
                            style: theme.textTheme.bodySmall,
                          ),
                          onTap: () => Navigator.of(context).pop(project),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
