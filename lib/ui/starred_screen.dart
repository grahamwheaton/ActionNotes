import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/checklist_item.dart';
import '../models/project.dart';
import '../state/app_state.dart';
import 'checklist_view.dart';
import 'home_shell.dart';
import 'tag_pill.dart';

/// One starred item and the project it belongs to.
class StarredItem {
  const StarredItem(this.project, this.index, this.item);

  final Project project;

  /// Index into the project's own item list, so opening it can point at the
  /// right line.
  final int index;
  final ChecklistItem item;
}

/// Every starred item still to do, from every project.
///
/// Stars pin an item to the top of its own list, which leaves what matters
/// spread across as many lists as there are projects. This is the one screen
/// that answers "what am I doing today".
List<StarredItem> starredAcross(List<Project> projects) {
  final found = <StarredItem>[];

  for (final project in projects) {
    for (var index = 0; index < project.items.length; index++) {
      final item = project.items[index];
      if (item.starred && !item.done) {
        found.add(StarredItem(project, index, item));
      }
    }
  }

  return found;
}

class StarredScreen extends StatelessWidget {
  const StarredScreen({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const StarredScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<AppState>();
    final starred = starredAcross(state.projects);

    return Scaffold(
      appBar: AppBar(title: const Text('Starred')),
      body: starred.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Nothing is starred. Star an item and it will show here, '
                  'whichever project it is in.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          : ListView.separated(
              itemCount: starred.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, position) {
                final entry = starred[position];
                final tags = entry.item.tags;

                return ListTile(
                  leading: Icon(Icons.star, color: theme.colorScheme.primary),
                  title: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (entry.item.title.isNotEmpty) Text(entry.item.title),
                      for (final tag in tags) TagPill(tag: tag, faded: false),
                    ],
                  ),
                  subtitle: Text(
                    entry.project.title,
                    style: theme.textTheme.bodySmall,
                  ),
                  trailing: entry.item.hasNotes
                      ? Icon(
                          Icons.notes,
                          size: 18,
                          color: theme.colorScheme.onSurfaceVariant,
                        )
                      : null,
                  onTap: () {
                    final state = context.read<AppState>();
                    state.select(entry.project.slug);
                    state.revealItem(entry.project.slug, entry.index);

                    // On a phone the checklist is a screen, so replace this
                    // one rather than stacking; on a desktop selecting it is
                    // enough, and closing this gets out of the way.
                    final wide = MediaQuery.sizeOf(context).width >=
                        HomeShell.sidebarBreakpoint;
                    if (wide) {
                      Navigator.of(context).pop();
                    } else {
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute(
                          builder: (_) =>
                              ChecklistView(slug: entry.project.slug),
                        ),
                      );
                    }
                  },
                );
              },
            ),
    );
  }
}
