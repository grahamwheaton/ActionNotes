import '../models/project.dart';

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
