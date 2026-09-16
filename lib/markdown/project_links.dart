import '../models/project.dart';

/// Links between projects.
///
/// Notes are written with ordinary markdown links, relative to `projects/`, so
/// a link works in three places at once: in the app, on github.com when
/// browsing the file, and in Obsidian, which follows relative links as well as
/// its own. Obsidian's `[[Wikilink]]` form is accepted on the way in — pasted
/// from a vault, or simply typed by habit — and rewritten to the portable form
/// when the note is saved.
class ProjectLinks {
  ProjectLinks._();

  static final _wikilink = RegExp(r'\[\[([^\]\[|]+)(?:\|([^\]\[]+))?\]\]');

  /// The markdown for linking to [project].
  static String linkTo(Project project) =>
      '[${project.title}](${project.slug}.md)';

  /// The slug a link points at, or null if it leads somewhere else — an
  /// external URL, or an attachment.
  static String? targetSlug(String href) {
    if (href.contains('://')) return null;

    var path = href.split('#').first.trim();
    if (path.isEmpty) return null;

    // Tolerate the forms a person or another editor might write.
    for (final prefix in ['./', '/', 'projects/', '../projects/']) {
      if (path.startsWith(prefix)) {
        path = path.substring(prefix.length);
        break;
      }
    }
    if (path.contains('/')) return null;

    return path.endsWith('.md')
        ? path.substring(0, path.length - 3)
        : path;
  }

  /// Rewrites `[[Wikilinks]]` into portable markdown links, matching each
  /// target against [projects] by title or slug.
  ///
  /// An unmatched wikilink is left exactly as written rather than turned into
  /// a link that goes nowhere.
  static String normalize(String notes, List<Project> projects) {
    if (!notes.contains('[[')) return notes;

    return notes.replaceAllMapped(_wikilink, (match) {
      final target = match.group(1)!.trim();
      final label = match.group(2)?.trim();

      final project = resolve(target, projects);
      if (project == null) return match.group(0)!;

      return '[${label ?? project.title}](${project.slug}.md)';
    });
  }

  /// Finds the project a link target names, by slug first and then by title.
  static Project? resolve(String target, List<Project> projects) {
    final needle = target.trim().toLowerCase();
    if (needle.isEmpty) return null;

    final slug = needle.endsWith('.md')
        ? needle.substring(0, needle.length - 3)
        : needle;

    for (final project in projects) {
      if (project.slug.toLowerCase() == slug) return project;
    }
    for (final project in projects) {
      if (project.title.toLowerCase() == needle) return project;
    }
    return null;
  }

  /// Every project [notes] links to, for showing what a note points at.
  static List<String> outgoingSlugs(String notes) {
    final slugs = <String>{};
    for (final match
        in RegExp(r'\]\(([^)\s]+)\)').allMatches(notes)) {
      final slug = targetSlug(match.group(1)!);
      if (slug != null) slugs.add(slug);
    }
    for (final match in _wikilink.allMatches(notes)) {
      slugs.add(match.group(1)!.trim());
    }
    return slugs.toList();
  }
}
