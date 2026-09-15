import 'checklist_item.dart';

/// One markdown file under `projects/`, parsed into something the UI can edit.
class Project {
  Project({
    required this.slug,
    required this.title,
    this.items = const [],
    this.notes = '',
    this.created,
    this.updated,
    this.extraFrontMatter = const {},
    this.sha,
    this.dirty = false,
  });

  /// Filename without the `.md`. Stable for the life of the project.
  final String slug;
  final String title;
  final List<ChecklistItem> items;

  /// Free text that follows the checklist in the file.
  final String notes;

  final DateTime? created;
  final DateTime? updated;

  /// Front-matter keys the app does not itself use, kept so hand-added
  /// metadata survives a round trip.
  final Map<String, String> extraFrontMatter;

  /// The blob SHA GitHub last gave us for this file. Null means the file has
  /// never been seen on the remote.
  final String? sha;

  /// True when the local copy has edits that are not yet on GitHub.
  final bool dirty;

  String get path => 'projects/$slug.md';

  int get doneCount => items.where((i) => i.done).length;

  Project copyWith({
    String? title,
    List<ChecklistItem>? items,
    String? notes,
    DateTime? created,
    DateTime? updated,
    Map<String, String>? extraFrontMatter,
    String? sha,
    bool? dirty,
  }) {
    return Project(
      slug: slug,
      title: title ?? this.title,
      items: items ?? this.items,
      notes: notes ?? this.notes,
      created: created ?? this.created,
      updated: updated ?? this.updated,
      extraFrontMatter: extraFrontMatter ?? this.extraFrontMatter,
      sha: sha ?? this.sha,
      dirty: dirty ?? this.dirty,
    );
  }

  /// Turns a title into a filename-safe slug: `House move!` -> `house-move`.
  static String slugify(String title) {
    final base = title
        .toLowerCase()
        .replaceAll(RegExp(r"[^a-z0-9]+"), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return base.isEmpty ? 'project' : base;
  }
}
