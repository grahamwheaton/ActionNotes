import '../markdown/project_markdown.dart';
import '../markdown/project_merge.dart';
import '../models/project.dart';
import 'github_client.dart';
import 'local_store.dart';

class SyncResult {
  const SyncResult({
    required this.projects,
    this.error,
    this.pending = 0,
    this.conflicts = const [],
  });

  final List<Project> projects;

  /// Human-readable reason the sync did not fully succeed, if any.
  final String? error;

  /// How many projects still hold unpushed edits.
  final int pending;

  /// Projects that changed on both sides and need a decision.
  final List<ProjectConflict> conflicts;

  bool get ok => error == null && conflicts.isEmpty;
}

/// A project edited both here and on GitHub.
class ProjectConflict {
  const ProjectConflict({required this.local, required this.remote});

  /// This device's version, still holding the edits that could not be pushed.
  final Project local;

  /// GitHub's version, carrying the SHA a resolving write has to use.
  final Project remote;

  String get slug => local.slug;
}

/// Reconciles the local cache with the GitHub repo.
///
/// The rule is simple and predictable: a project with local edits wins and is
/// pushed; a project without them takes whatever the remote says. That keeps
/// offline edits safe without needing a merge algorithm, at the cost of
/// overwriting a remote edit made to a file you had also edited locally — which
/// is why a push that fails the SHA check is surfaced rather than forced.
class SyncService {
  SyncService({required this.localStore, GitHubClient Function(GitHubConfig)? clientFactory})
      : _clientFactory = clientFactory ?? GitHubClient.new;

  final LocalStore localStore;

  /// How a client is built for a config. Injected so tests can stub the HTTP
  /// layer without reaching the network.
  final GitHubClient Function(GitHubConfig) _clientFactory;

  Future<SyncResult> sync(GitHubConfig config) async {
    final local = await localStore.loadAll();

    if (!config.isComplete) {
      return SyncResult(
        projects: local,
        error: 'Add your GitHub repo and token in Settings to sync.',
        pending: local.where((p) => p.dirty).length,
      );
    }

    final client = _clientFactory(config);
    try {
      final byslug = {for (final project in local) project.slug: project};
      final problems = <String>[];
      final conflicts = <ProjectConflict>[];

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
          // 409 means the file moved on under us. 422 means our SHA was
          // rejected outright, which happens when the local copy never had
          // one but the file exists on GitHub — the same situation.
          if (error.statusCode == 409 || error.statusCode == 422) {
            final file = await client.readFile(project.path);
            if (file == null) {
              // The file is gone, so there is nothing to conflict with;
              // the next attempt can create it.
              problems.add(
                '"${project.title}" could not be pushed: ${error.message}',
              );
              continue;
            }
            conflicts.add(
              ProjectConflict(
                local: project,
                remote: ProjectMarkdown.parse(
                  file.content,
                  slug: project.slug,
                  sha: file.sha,
                ),
              ),
            );
          } else {
            problems.add(
              '"${project.title}" could not be pushed: ${error.message}',
            );
          }
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
        conflicts: conflicts,
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

    final client = _clientFactory(config);
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

  /// Settles a conflict and returns the project to keep locally.
  ///
  /// Every outcome ends with local and GitHub agreeing, so the project stops
  /// being stuck: keeping GitHub's copy needs no write, and the other two push
  /// using the SHA read back when the conflict was found.
  Future<Project> resolve(
    GitHubConfig config,
    ProjectConflict conflict,
    ConflictResolution resolution,
  ) async {
    if (resolution == ConflictResolution.keepRemote) {
      final settled = conflict.remote.copyWith(dirty: false);
      await localStore.save(settled);
      return settled;
    }

    final chosen = switch (resolution) {
      ConflictResolution.keepLocal => conflict.local,
      ConflictResolution.merge => ProjectMerge.merge(
          local: conflict.local,
          remote: conflict.remote,
        ),
      ConflictResolution.keepRemote => conflict.remote,
    };

    // The remote SHA is the current one, so this write is accepted.
    final toPush = chosen.copyWith(sha: conflict.remote.sha, dirty: true);

    if (!config.isComplete) {
      await localStore.save(toPush);
      return toPush;
    }

    final client = _clientFactory(config);
    try {
      final sha = await client.writeFile(
        path: toPush.path,
        content: ProjectMarkdown.serialize(toPush),
        message: 'Resolve ${toPush.title}',
        sha: conflict.remote.sha,
      );
      final settled = toPush.copyWith(sha: sha, dirty: false);
      await localStore.save(settled);
      return settled;
    } catch (_) {
      // Keep the chosen content with the fresh SHA, so a later sync can retry
      // rather than failing the same way forever.
      await localStore.save(toPush);
      return toPush;
    } finally {
      client.dispose();
    }
  }

  Future<String?> deleteRemote(GitHubConfig config, Project project) async {
    if (!config.isComplete || project.sha == null) return null;

    final client = _clientFactory(config);
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
