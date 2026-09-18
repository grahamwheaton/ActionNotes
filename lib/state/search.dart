import '../markdown/item_tags.dart';
import '../markdown/mentions.dart';
import '../models/project.dart';

/// A tag and how many items carry it.
class TagCount {
  const TagCount(this.tag, this.count);

  final String tag;
  final int count;
}

/// Where a match was found, so a result can say why it matched.
enum SearchField { projectTitle, itemText, itemNotes, projectNotes }

/// One hit, pointing at the project and, where relevant, the item.
class SearchHit {
  const SearchHit({
    required this.project,
    required this.field,
    required this.text,
    this.itemIndex,
  });

  final Project project;
  final SearchField field;

  /// The matching line, for showing underneath the project name.
  final String text;

  /// Null when the project itself matched rather than one of its items.
  final int? itemIndex;
}

/// Searches every project's titles, items and notes.
///
/// Plain case-insensitive substring matching: the corpus is a handful of
/// markdown files, so there is nothing to gain from an index, and a
/// predictable match is easier to trust than a clever one.
class ProjectSearch {
  ProjectSearch._();

  static List<SearchHit> run(List<Project> projects, String query) {
    // `[bug]` asks for that tag rather than for the characters, which is what
    // tapping a pill sends, and is the one place a query means something
    // other than "contains this".
    final tag = ItemTags.queryTag(query);
    if (tag != null) return byTag(projects, tag);

    // `@claude` asks who is being waited on, which is the question the
    // mention was written to ask.
    final name = Mentions.queryName(query);
    if (name != null) return byMention(projects, name);

    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];

    final hits = <SearchHit>[];

    for (final project in projects) {
      if (project.title.toLowerCase().contains(needle)) {
        hits.add(SearchHit(
          project: project,
          field: SearchField.projectTitle,
          text: project.title,
        ));
      }

      for (var index = 0; index < project.items.length; index++) {
        final item = project.items[index];

        if (item.text.toLowerCase().contains(needle)) {
          hits.add(SearchHit(
            project: project,
            field: SearchField.itemText,
            text: item.text,
            itemIndex: index,
          ));
          continue;
        }

        // A note only reports the line that matched, not the whole note.
        final line = _matchingLine(item.notes, needle);
        if (line != null) {
          hits.add(SearchHit(
            project: project,
            field: SearchField.itemNotes,
            text: line,
            itemIndex: index,
          ));
        }
      }

      final projectNote = _matchingLine(project.notes, needle);
      if (projectNote != null) {
        hits.add(SearchHit(
          project: project,
          field: SearchField.projectNotes,
          text: projectNote,
        ));
      }
    }

    return hits;
  }

  /// Every item carrying [tag], across every project.
  ///
  /// An exact tag match, not a substring one: `[app]` should not drag in
  /// `[appointments]`, or a pill would find things the person did not tag.
  static List<SearchHit> byTag(List<Project> projects, String tag) {
    final hits = <SearchHit>[];

    for (final project in projects) {
      for (var index = 0; index < project.items.length; index++) {
        final item = project.items[index];
        if (!item.tags.any((found) => found.toLowerCase() == tag.toLowerCase())) {
          continue;
        }
        hits.add(SearchHit(
          project: project,
          field: SearchField.itemText,
          text: item.text,
          itemIndex: index,
        ));
      }
    }

    return hits;
  }

  /// Every tag in use, most used first and alphabetically within that.
  ///
  /// Tags can be searched but not remembered, so this is what makes them
  /// findable: the list is built from the items themselves, which means it
  /// cannot go stale.
  static List<TagCount> tags(List<Project> projects) {
    final counts = <String, int>{};
    final spellings = <String, String>{};

    for (final project in projects) {
      for (final item in project.items) {
        for (final tag in item.tags) {
          final key = tag.toLowerCase();
          counts[key] = (counts[key] ?? 0) + 1;
          spellings.putIfAbsent(key, () => tag);
        }
      }
    }

    final tags = [
      for (final entry in counts.entries) TagCount(spellings[entry.key]!, entry.value),
    ];

    tags.sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      return byCount != 0
          ? byCount
          : a.tag.toLowerCase().compareTo(b.tag.toLowerCase());
    });
    return tags;
  }

  /// Every item mentioning [name] that has not been answered, across every
  /// project. This is the model's inbox, and the person's way of seeing what
  /// they have asked for.
  static List<SearchHit> byMention(List<Project> projects, String name) {
    final wanted = name.trim().toLowerCase().replaceFirst('@', '');
    final hits = <SearchHit>[];

    for (final project in projects) {
      for (var index = 0; index < project.items.length; index++) {
        final item = project.items[index];
        if (!item.awaiting.any((who) => who.toLowerCase() == wanted)) continue;

        hits.add(SearchHit(
          project: project,
          field: SearchField.itemText,
          text: item.text,
          itemIndex: index,
        ));
      }
    }

    return hits;
  }

  /// Who is being waited on, and how many items each, most first. Shown in
  /// the search screen beside the tags, since it answers the same kind of
  /// question.
  static List<TagCount> mentions(List<Project> projects) {
    final counts = <String, int>{};
    final spellings = <String, String>{};

    for (final project in projects) {
      for (final item in project.items) {
        if (item.done) continue;
        for (final name in item.awaiting) {
          final key = name.toLowerCase();
          counts[key] = (counts[key] ?? 0) + 1;
          spellings.putIfAbsent(key, () => name);
        }
      }
    }

    final names = [
      for (final entry in counts.entries)
        TagCount(spellings[entry.key]!, entry.value),
    ];
    names.sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      return byCount != 0
          ? byCount
          : a.tag.toLowerCase().compareTo(b.tag.toLowerCase());
    });
    return names;
  }

  /// The first line of [text] containing [needle], trimmed, or null.
  static String? _matchingLine(String text, String needle) {
    for (final line in text.split('\n')) {
      if (line.toLowerCase().contains(needle)) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) return trimmed;
      }
    }
    return null;
  }
}
