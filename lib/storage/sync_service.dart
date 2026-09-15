import '../markdown/project_markdown.dart';
import '../models/project.dart';
import 'github_client.dart';
import 'local_store.dart';

class SyncResult {
  const SyncResult({required this.projects, this.error, this.pending = 0});

  final List<Project> projects;

  /// Human-readable reason the sync did not fully succeed, if any.
  final String? error;

  /// How many projects still hold unpushed edits.
  final int pending;

  bool get ok => error == null;
}

/// Reconciles the local cache with the GitHub repo.
///
/// The rule is simple and predictable: a project with local edits wins and is
/// pushed; a project without them takes whatever the remote says. That keeps
/// offline edits safe without needing a merge algorithm, at the cost of
/// overwriting a remote edit made to a file you had also edited locally — which
/// is why a push that fails the SHA check is surfaced rather than forced.
class SyncService {
  SyncService({required this.localStore});

  final LocalStore localStore;

  Future<SyncResult> sync(GitHubConfig config) async {
    final local = await localStore.loadAll();

    if (!config.isComplete) {
      return SyncResult(
        projects: local,
        error: 'Add your GitHub repo and token in Settings to sync.',
        pending: local.where((p) => p.dirty).length,
      );
    }

    final client = GitHubClient(config);
    try {
      final byslug = {for (final project in local) project.slug: project};
      final problems = <String>[];

      // Push anything edited offline first, so a pull cannot clobber it.
      for (final project in local.where((p) => p.dirty)) {
        try {
          final sha = await client.writeFile(
            path: project.path,
            content: ProjectMarkdown.serialize(project),
            message: 'Update ${project.title}',
            sha: project.sha,
          );
          final pushed = project.copyWith(sha: sha, dirty: false);
          byslug[project.slug] = pushed;
          await localStore.save(pushed);
        } on GitHubException catch (error) {
          problems.add(
            error.statusCode == 409
                ? '"${project.title}" changed on GitHub too — kept your copy, not pushed.'
                : '"${project.title}" could not be pushed: ${error.message}',
          );
        }
      }

      // Pull everything else.
      for (final path in await client.listProjectPaths()) {
        final slug = path.split('/').last.replaceAll(RegExp(r'\.md$'), '');
        final existing = byslug[slug];
        if (existing != null && existing.dirty) continue;

        final file = await client.readFile(path);
        if (file == null) continue;

        final remote =
            ProjectMarkdown.parse(file.content, slug: slug, sha: file.sha);
        if (existing != null && existing.sha == file.sha) continue;

        byslug[slug] = remote;
        await localStore.save(remote);
      }

      final projects = byslug.values.toList()
        ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

      return SyncResult(
        projects: projects,
        error: problems.isEmpty ? null : problems.join('\n'),
        pending: projects.where((p) => p.dirty).length,
      );
    } on GitHubException catch (error) {
      return SyncResult(
        projects: local,
        error: error.isFatal
            ? 'GitHub rejected the request (${error.statusCode}): ${error.message}'
            : 'Sync failed: ${error.message}',
        pending: local.where((p) => p.dirty).length,
      );
    } catch (error) {
      return SyncResult(
        projects: local,
        error: 'Could not reach GitHub. Your edits are saved on this device.',
        pending: local.where((p) => p.dirty).length,
      );
    } finally {
      client.dispose();
    }
  }

  /// Pushes one project. Returns the project with a refreshed SHA, or with
  /// `dirty` still set if the push could not happen.
  Future<Project> push(GitHubConfig config, Project project) async {
    if (!config.isComplete) return project;

    final client = GitHubClient(config);
    try {
      final sha = await client.writeFile(
        path: project.path,
        content: ProjectMarkdown.serialize(project),
        message: 'Update ${project.title}',
        sha: project.sha,
      );
      return project.copyWith(sha: sha, dirty: false);
    } catch (_) {
      return project;
    } finally {
      client.dispose();
    }
  }

  Future<String?> deleteRemote(GitHubConfig config, Project project) async {
    if (!config.isComplete || project.sha == null) return null;

    final client = GitHubClient(config);
    try {
      await client.deleteFile(
        path: project.path,
        sha: project.sha!,
        message: 'Delete ${project.title}',
      );
      return null;
    } on GitHubException catch (error) {
      return 'Removed here, but GitHub still has the file: ${error.message}';
    } catch (_) {
      return 'Removed here, but GitHub could not be reached.';
    } finally {
      client.dispose();
    }
  }
}
