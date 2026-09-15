import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../markdown/project_markdown.dart';
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

  File _metaFile(Directory root, String slug) => File('${root.path}/$slug.json');

  File _markdownFile(Directory root, String slug) => File('${root.path}/$slug.md');

  Future<List<Project>> loadAll() async {
    final root = await _ensureRoot();
    final projects = <Project>[];

    await for (final entity in root.list()) {
      if (entity is! File || !entity.path.endsWith('.md')) continue;
      final slug = entity.uri.pathSegments.last.replaceAll(RegExp(r'\.md$'), '');
      final source = await entity.readAsString();
      final meta = await _readMeta(root, slug);
      projects.add(
        ProjectMarkdown.parse(source, slug: slug, sha: meta['sha'] as String?)
            .copyWith(dirty: meta['dirty'] as bool? ?? false),
      );
    }

    projects.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
    return projects;
  }

  Future<void> save(Project project) async {
    final root = await _ensureRoot();
    await _markdownFile(root, project.slug)
        .writeAsString(ProjectMarkdown.serialize(project));
    await _metaFile(root, project.slug).writeAsString(
      jsonEncode({'sha': project.sha, 'dirty': project.dirty}),
    );
  }

  Future<void> delete(String slug) async {
    final root = await _ensureRoot();
    for (final file in [_markdownFile(root, slug), _metaFile(root, slug)]) {
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
