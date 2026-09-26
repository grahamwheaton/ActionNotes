import 'checklist_item.dart';
import 'notes_source.dart';

/// How a project is meant to be read.
///
/// The file format is the same either way — a notes project is simply one with
/// no checklist lines — so this only decides which view opens, and a project
/// switched to notes and back loses nothing.
enum ProjectMode {
  tasks,
  notes,

  /// A day at a time: what was written today is open, and the days before it
  /// are folded up under their dates.
  ///
  /// The file is an ordinary project whose sections happen to be dates, so a
  /// feed read anywhere else is a list under date headings — which is what
  /// anyone would have written by hand anyway.
  feed,
  kanban;

  static ProjectMode parse(String? raw) => switch (raw?.trim().toLowerCase()) {
    'notes' => ProjectMode.notes,
    'feed' => ProjectMode.feed,
    'kanban' => ProjectMode.kanban,
    _ => ProjectMode.tasks,
  };

  String get name => switch (this) {
    ProjectMode.notes => 'notes',
    ProjectMode.feed => 'feed',
    ProjectMode.kanban => 'kanban',
    ProjectMode.tasks => 'tasks',
  };
}

/// A `##` section of a project.
///
/// A block holds items (the project's items carrying this title), prose, or
/// both. Its kind is read from what is in it rather than declared, so a heading
/// typed on GitHub becomes a block without anyone having to say which sort —
/// which is the point of using headings for this rather than inventing syntax.
class ProjectBlock {
  const ProjectBlock({required this.title, this.body = ''});

  final String title;

  /// Prose under the heading, below any of its items.
  final String body;

  ProjectBlock copyWith({String? title, String? body}) =>
      ProjectBlock(title: title ?? this.title, body: body ?? this.body);

  @override
  bool operator ==(Object other) =>
      other is ProjectBlock && other.title == title && other.body == body;

  @override
  int get hashCode => Object.hash(title, body);

  @override
  String toString() => 'ProjectBlock($title)';
}

/// One markdown file under `projects/`, parsed into something the UI can edit.
class Project {
  Project({
    required this.slug,
    required this.title,
    this.items = const [],
    this.notes = '',
    this.mode = ProjectMode.tasks,
    this.blocks = const [],
    this.created,
    this.updated,
    this.extraFrontMatter = const {},
    this.sha,
    this.dirty = false,
    this.sourceId = NotesSource.mineId,
  });

  /// How the app refers to this project, and unique across every notebook.
  ///
  /// For your own notes this is the filename, as it always was. For a project
  /// in a shared notebook it carries the notebook in front of it, because two
  /// notebooks can each hold a `shopping.md` and the app needs to be able to
  /// tell them apart without every screen having to carry a notebook around
  /// beside the name.
  final String slug;
  final String title;
  final List<ChecklistItem> items;

  /// Free text that follows the checklist in the file. In a notes project it
  /// is the whole of the body.
  final String notes;

  /// Which view opens for this project. Written to the front matter only when
  /// it is not the default, so a task project's file does not change.
  final ProjectMode mode;

  /// The `##` headings in the file, in the order they appear. Empty for a
  /// project that has none, which is every project written before blocks
  /// existed — so their files are untouched by this.
  final List<ProjectBlock> blocks;

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

  /// Which notebook this came from.
  final String sourceId;

  /// What the file is actually called, in whichever repo it lives in.
  ///
  /// Everything written into the repo — the file, its attachments, its canvas
  /// layout — is named by this rather than by [slug], because the repo has
  /// never heard of the notebook the app keeps it under.
  String get fileSlug {
    final prefix = '$sourceId~';
    return slug.startsWith(prefix) ? slug.substring(prefix.length) : slug;
  }

  bool get isShared => sourceId != NotesSource.mineId;

  /// The app-wide name for a project called [fileSlug] in [sourceId].
  ///
  /// `~` because a slug is only ever letters, digits and dashes, so it can
  /// never turn up in one by accident.
  static String keyOf(String sourceId, String fileSlug) =>
      sourceId == NotesSource.mineId ? fileSlug : '$sourceId~$fileSlug';

  String get path => 'projects/$fileSlug.md';

  int get doneCount => items.where((i) => i.done).length;

  /// The items under [title], or the ones above the first heading for null.
  List<ChecklistItem> itemsIn(String? title) =>
      items.where((item) => item.block == title).toList();

  /// Indices into [items] for the items under [title], so a grouped view can
  /// still address the flat list.
  List<int> indicesIn(String? title) => [
    for (var i = 0; i < items.length; i++)
      if (items[i].block == title) i,
  ];

  /// True when the project is one plain list, as every project was before
  /// blocks — the case the view should not dress up with headings.
  bool get isFlat => blocks.isEmpty;

  Project copyWith({
    String? title,
    List<ChecklistItem>? items,
    String? notes,
    ProjectMode? mode,
    List<ProjectBlock>? blocks,
    DateTime? created,
    DateTime? updated,
    Map<String, String>? extraFrontMatter,
    String? sha,
    bool? dirty,
    String? sourceId,
  }) {
    return Project(
      slug: slug,
      sourceId: sourceId ?? this.sourceId,
      title: title ?? this.title,
      items: items ?? this.items,
      notes: notes ?? this.notes,
      mode: mode ?? this.mode,
      blocks: blocks ?? this.blocks,
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
