import '../models/notes_source.dart';
import '../models/project.dart';

/// Relative portals stay in their notebook; cross-notebook portals carry the
/// source explicitly, including `mine~` when linking back to personal notes.
class PortalLinks {
  PortalLinks._();

  static String _source(String slug) => slug.contains('~')
      ? slug.substring(0, slug.indexOf('~'))
      : NotesSource.mineId;

  static String reference(Project project, String canvasSlug) =>
      project.sourceId == _source(canvasSlug)
      ? project.fileSlug
      : '${project.sourceId}~${project.fileSlug}';

  static Project? resolve(
    String reference,
    String canvasSlug,
    List<Project> projects,
  ) {
    final separator = reference.indexOf('~');
    final source = separator < 0
        ? _source(canvasSlug)
        : reference.substring(0, separator);
    final file = separator < 0 ? reference : reference.substring(separator + 1);
    return projects
        .where((p) => p.sourceId == source && p.fileSlug == file)
        .firstOrNull;
  }
}
