import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../markdown/item_tags.dart';
import '../state/app_state.dart';
import '../state/search.dart';
import 'checklist_view.dart';
import 'tag_pill.dart';

/// Searches across every project's titles, items and notes.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.initialQuery = ''});

  /// What to search for on opening. Tapping a tag pill arrives here with
  /// `[tag]`, which searches for that tag rather than for those characters.
  final String initialQuery;

  static Future<void> open(BuildContext context, {String query = ''}) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SearchScreen(initialQuery: query)),
    );
  }

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late final _controller = TextEditingController(text: widget.initialQuery);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<AppState>();
    final query = _controller.text.trim();
    final hits = ProjectSearch.run(state.projects, query);

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search projects, items and notes',
            border: InputBorder.none,
            filled: false,
          ),
          onChanged: (_) => setState(() {}),
        ),
        actions: [
          if (query.isNotEmpty)
            IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.close),
              onPressed: () => setState(_controller.clear),
            ),
        ],
      ),
      body: query.isEmpty
          ? _Message(
              text: 'Type to search across every project.',
              theme: theme,
            )
          : hits.isEmpty
              ? _Message(
                  text: ItemTags.queryTag(query) == null
                      ? 'Nothing matches "$query".'
                      : 'Nothing is tagged ${ItemTags.queryTag(query)}.',
                  theme: theme,
                )
              : ListView.separated(
                  itemCount: hits.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) => _HitTile(hit: hits[index]),
                ),
    );
  }
}

/// A hit's line. An item's own text shows its tags as pills, the same as in
/// the list; a note's line is left as the markdown it is.
class _HitText extends StatelessWidget {
  const _HitText({required this.hit});

  final SearchHit hit;

  @override
  Widget build(BuildContext context) {
    final tags =
        hit.field == SearchField.itemText ? ItemTags.parse(hit.text) : const <String>[];

    if (tags.isEmpty) {
      return Text(hit.text, maxLines: 2, overflow: TextOverflow.ellipsis);
    }

    final title = ItemTags.strip(hit.text);
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (title.isNotEmpty)
          Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
        for (final tag in tags) TagPill(tag: tag, faded: false),
      ],
    );
  }
}

class _HitTile extends StatelessWidget {
  const _HitTile({required this.hit});

  final SearchHit hit;

  /// Says where the match came from, so two hits in one project are
  /// distinguishable.
  String get _where => switch (hit.field) {
        SearchField.projectTitle => 'Project',
        SearchField.itemText => hit.project.title,
        SearchField.itemNotes => '${hit.project.title} · note',
        SearchField.projectNotes => '${hit.project.title} · project note',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      leading: Icon(
        switch (hit.field) {
          SearchField.projectTitle => Icons.checklist,
          SearchField.itemText => Icons.check_box_outline_blank,
          _ => Icons.notes,
        },
        size: 20,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      title: _HitText(hit: hit),
      subtitle: Text(_where, style: theme.textTheme.bodySmall),
      onTap: () {
        final state = context.read<AppState>();
        state.select(hit.project.slug);

        // On a phone the checklist is a screen, so replace the search with it
        // rather than stacking; on a desktop selecting is enough.
        final wide = MediaQuery.sizeOf(context).width >= 720;
        if (wide) {
          Navigator.of(context).pop();
        } else {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => ChecklistView(slug: hit.project.slug),
            ),
          );
        }
      },
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, required this.theme});

  final String text;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
