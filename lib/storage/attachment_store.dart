import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'github_client.dart';

/// On-device copy of note attachments.
///
/// Images referenced from item notes live in the repo, which is usually
/// private, so they cannot be rendered straight from a URL. They are cached
/// here on first use and read from disk after that.
class AttachmentStore {
  Directory? _root;

  Future<Directory> _ensureRoot() async {
    if (_root != null) return _root!;
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/actionnotes/attachments');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _root = dir;
  }

  /// Repo-relative path for an attachment, e.g. `attachments/trip/photo.png`.
  static String repoPath(String projectSlug, String fileName) =>
      '${GitHubClient.attachmentsDir}/$projectSlug/$fileName';

  /// How an item's notes refer to the attachment. Relative, so GitHub renders
  /// the image when viewing `projects/<slug>.md` in the browser.
  static String markdownPath(String projectSlug, String fileName) =>
      '../${repoPath(projectSlug, fileName)}';

  /// Turns a reference found in notes back into a repo path, or null if it
  /// points somewhere else (an external URL, say).
  static String? resolveRepoPath(String reference) {
    final cleaned = reference.startsWith('../')
        ? reference.substring(3)
        : reference.startsWith('/')
            ? reference.substring(1)
            : reference;
    if (!cleaned.startsWith('${GitHubClient.attachmentsDir}/')) return null;
    return cleaned;
  }

  Future<File> _fileFor(String repoPath) async {
    final root = await _ensureRoot();
    // Flatten the repo path so nested directories need not be created.
    final name = repoPath.replaceAll('/', '_');
    return File('${root.path}/$name');
  }

  Future<File?> cached(String repoPath) async {
    final file = await _fileFor(repoPath);
    return await file.exists() ? file : null;
  }

  Future<File> save(String repoPath, List<int> bytes) async {
    final file = await _fileFor(repoPath);
    await file.writeAsBytes(bytes);
    return file;
  }

  /// Returns the local copy, fetching it from GitHub if it is not cached yet.
  /// Returns null when the image cannot be reached, so the UI can show a
  /// placeholder rather than fail.
  Future<File?> resolve(String repoPath, GitHubConfig config) async {
    final local = await cached(repoPath);
    if (local != null) return local;
    if (!config.isComplete) return null;

    final client = GitHubClient(config);
    try {
      final bytes = await client.readBytes(repoPath);
      if (bytes == null) return null;
      return await save(repoPath, bytes);
    } catch (_) {
      return null;
    } finally {
      client.dispose();
    }
  }

  /// Builds a filename that will not collide with one already in the project.
  static String uniqueFileName(String original, Set<String> taken) {
    final safe = original
        .split(RegExp(r'[/\\]'))
        .last
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
    if (!taken.contains(safe)) return safe;

    final dot = safe.lastIndexOf('.');
    final stem = dot > 0 ? safe.substring(0, dot) : safe;
    final extension = dot > 0 ? safe.substring(dot) : '';
    var suffix = 2;
    while (taken.contains('$stem-$suffix$extension')) {
      suffix++;
    }
    return '$stem-$suffix$extension';
  }
}
