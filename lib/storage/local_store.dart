import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../markdown/project_markdown.dart';
import '../models/canvas_layout.dart';
import '../models/project.dart';

/// The on-device copy of the notes.
///
/// Every edit lands here first, so an edit made with no signal is never lost —
/// it just sits with `dirty: true` until a sync can push it.
class LocalStore {
  Directory? _root;

  Future<Directory> _ensureRoot() async {
    if (_root != null) return _root!;
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/actionnotes/projects');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _root = dir;
  }

  File _metaFile(Directory root, String slug) =>
      File('${root.path}/$slug.json');

  File _markdownFile(Directory root, String slug) =>
      File('${root.path}/$slug.md');

  /// The canvas layout, kept beside the project as it is in the repo.
  File _layoutFile(Directory root, String slug) =>
      File('${root.path}/$slug.canvas.json');

  Future<List<Project>> loadAll() async {
    final root = await _ensureRoot();
    final projects = <Project>[];

    await for (final entity in root.list()) {
      if (entity is! File || !entity.path.endsWith('.md')) continue;
      final slug = entity.uri.pathSegments.last.replaceAll(
        RegExp(r'\.md$'),
        '',
      );
      final source = await entity.readAsString();
      final meta = await _readMeta(root, slug);
      projects.add(
        ProjectMarkdown.parse(
          source,
          slug: slug,
          sha: meta['sha'] as String?,
        ).copyWith(dirty: meta['dirty'] as bool? ?? false),
      );
    }

    projects.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
    return projects;
  }

  Future<void> save(Project project) async {
    final root = await _ensureRoot();
    await _markdownFile(
      root,
      project.slug,
    ).writeAsString(ProjectMarkdown.serialize(project));
    // Merged rather than replaced: the canvas layout keeps its own SHA in
    // here, and writing the project would otherwise forget it.
    final meta = Map<String, dynamic>.from(await _readMeta(root, project.slug))
      ..['sha'] = project.sha
      ..['dirty'] = project.dirty;
    await _metaFile(root, project.slug).writeAsString(jsonEncode(meta));
  }

  /// Where this project's canvases put things, or an empty layout when it has
  /// none — which is every project until one is made.
  Future<CanvasLayout> loadLayout(String slug) async {
    final root = await _ensureRoot();
    final file = _layoutFile(root, slug);
    if (!await file.exists()) return CanvasLayout.empty;

    final meta = await _readMeta(root, slug);
    return CanvasLayout.parse(
      await file.readAsString(),
      sha: meta['canvasSha'] as String?,
    );
  }

  Future<void> saveLayout(String slug, CanvasLayout layout) async {
    final root = await _ensureRoot();
    final file = _layoutFile(root, slug);

    if (layout.isEmpty) {
      if (await file.exists()) await file.delete();
    } else {
      await file.writeAsString(layout.toJsonString());
    }

    final meta = Map<String, dynamic>.from(await _readMeta(root, slug))
      ..['canvasSha'] = layout.sha;
    await _metaFile(root, slug).writeAsString(jsonEncode(meta));
  }

  Future<void> delete(String slug) async {
    final root = await _ensureRoot();
    for (final file in [
      _markdownFile(root, slug),
      _metaFile(root, slug),
      _layoutFile(root, slug),
    ]) {
      if (await file.exists()) await file.delete();
    }
  }

  Future<Map<String, dynamic>> _readMeta(Directory root, String slug) async {
    final file = _metaFile(root, slug);
    if (!await file.exists()) return const {};
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }
}
