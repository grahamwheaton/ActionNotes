import '../markdown/project_links.dart';
import '../markdown/project_markdown.dart';
import '../markdown/project_merge.dart';
import '../models/checklist_item.dart';
import '../models/canvas_layout.dart';
import '../models/notes_source.dart';
import '../models/project.dart';
import 'github_client.dart';
import 'local_store.dart';

class SyncResult {
  const SyncResult({
    required this.projects,
    this.error,
    this.pending = 0,
    this.merged = const [],
  });

  final List<Project> projects;

  /// Human-readable reason the sync did not fully succeed, if any.
  final String? error;

  /// How many projects still hold unpushed edits.
  final int pending;

  /// Titles that changed here and on GitHub at the same time and were
  /// combined. Worth mentioning, but nothing to answer.
  final List<String> merged;

  bool get ok => error == null;
}

/// What became of one project's push.
class _PushOutcome {
  const _PushOutcome({this.project, this.problem, this.merged = false});

  final Project? project;
  final String? problem;
  final bool merged;
}

/// Reconciles the local cache with the GitHub repo.
///
/// The rule is simple and predictable: a project with local edits wins and is
/// pushed; a project without them takes whatever the remote says. That keeps
/// offline edits safe without needing a merge algorithm, at the cost of
/// overwriting a remote edit made to a file you had also edited locally — which
/// is why a push that fails the SHA check is surfaced rather than forced.
class SyncService {
  SyncService({
    required this.localStore,
    GitHubClient Function(GitHubConfig)? clientFactory,
  }) : _clientFactory = clientFactory ?? GitHubClient.new;

  final LocalStore localStore;

  /// How a client is built for a config. Injected so tests can stub the HTTP
  /// layer without reaching the network.
  final GitHubClient Function(GitHubConfig) _clientFactory;

  /// How this service reaches GitHub, so that anything else needing a client
  /// — checking a share code, say — reaches it the same way rather than
  /// building its own and going round whatever a test has put in place.
  GitHubClient clientFor(GitHubConfig config) => _clientFactory(config);

  /// Brings one notebook into step with its repo.
  ///
  /// [sourceId] says which notebook: your own by default, or a shared one.
  /// The repo has never heard of notebooks, so everything inside here is
  /// keyed by the file's own name and only the projects handed back carry
  /// the notebook they came from.
  Future<SyncResult> sync(
    GitHubConfig config, {
    String sourceId = NotesSource.mineId,
  }) async {
    final local = await localStore.loadAll(sourceId: sourceId);

    if (!config.isComplete) {
      return SyncResult(
        projects: local,
        error: 'Add your GitHub repo and token in Settings to sync.',
        pending: local.where((p) => p.dirty).length,
      );
    }

    final client = _clientFactory(config);
    try {
      final byslug = {for (final project in local) project.fileSlug: project};
      final problems = <String>[];
      // Titles that came back changed on both sides and were combined. Not
      // errors: something to mention, not something to answer.
      final merged = <String>[];

      // Push anything edited offline first, so a pull cannot clobber it.
      for (final project in local.where((p) => p.dirty)) {
        final outcome = await _pushMerging(client, project, sourceId: sourceId);
        if (outcome.project != null) {
          byslug[project.fileSlug] = outcome.project!;
        }
        if (outcome.problem != null) problems.add(outcome.problem!);
        if (outcome.merged) merged.add(project.title);
      }

      // Pull everything else. The listing carries each file's SHA, so a file
      // that has not moved is skipped without being fetched — which is what
      // makes checking every few seconds affordable rather than a download of
      // every list, every time.
      for (final entry in await client.listProjects()) {
        final slug = entry.path
            .split('/')
            .last
            .replaceAll(RegExp(r'\.md$'), '');
        final existing = byslug[slug];
        if (existing != null && existing.dirty) continue;
        if (existing != null && existing.sha == entry.sha) continue;

        final file = await client.readFile(entry.path);
        if (file == null) continue;

        final remote = ProjectMarkdown.parse(
          file.content,
          slug: Project.keyOf(sourceId, slug),
          sha: file.sha,
        ).copyWith(sourceId: sourceId);

        byslug[slug] = remote;
        await localStore.save(remote, sourceId: sourceId);
      }

      final projects = byslug.values.toList()
        ..sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );

      return SyncResult(
        projects: projects,
        error: problems.isEmpty ? null : problems.join('\n'),
        pending: projects.where((p) => p.dirty).length,
        merged: merged,
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

  /// Pushes one project, combining both sides if it changed on GitHub too.
  ///
  /// Nobody is asked anything. A checklist merges by item text, so the result
  /// holds everything from either side, and prose that differs is kept twice
  /// with a marker rather than one copy being dropped — so combining can add
  /// something unexpected but cannot lose what somebody wrote. That is a
  /// trade worth making silently: the person who hits this is usually not the
  /// person who knows what a conflict is, and a list that has stopped saving
  /// while it waits to be asked about is worse than a list with a duplicate
  /// line in it.
  ///
  /// Tried a few times, because losing the race again while merging means
  /// somebody else pushed in between — which is ordinary when two people are
  /// on the same list, not a failure.
  Future<_PushOutcome> _pushMerging(
    GitHubClient client,
    Project project, {
    required String sourceId,
  }) async {
    var toPush = project;
    var combined = false;

    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final sha = await client.writeFile(
          path: toPush.path,
          content: ProjectMarkdown.serialize(toPush),
          message: combined
              ? 'Merge ${toPush.title}'
              : 'Update ${toPush.title}',
          sha: toPush.sha,
        );
        final pushed = toPush.copyWith(sha: sha, dirty: false);
        await localStore.save(pushed, sourceId: sourceId);
        return _PushOutcome(project: pushed, merged: combined);
      } on GitHubException catch (error) {
        // 409 means the file moved on under us. 422 means our SHA was
        // rejected outright, which happens when the local copy never had one
        // but the file exists on GitHub — the same situation.
        if (error.statusCode != 409 && error.statusCode != 422) {
          return _PushOutcome(
            project: project,
            problem: '"${project.title}" could not be pushed: ${error.message}',
          );
        }

        final file = await client.readFile(toPush.path);
        if (file == null) {
          // The file is gone, so there is nothing to combine with; the next
          // attempt can create it.
          return _PushOutcome(
            project: project,
            problem: '"${project.title}" could not be pushed: ${error.message}',
          );
        }

        final remote = ProjectMarkdown.parse(
          file.content,
          slug: project.slug,
          sha: file.sha,
        ).copyWith(sourceId: sourceId);

        toPush = ProjectMerge.merge(
          local: toPush,
          remote: remote,
        ).copyWith(sha: file.sha, dirty: true);
        combined = true;
      }
    }

    // Still being outrun after three goes. The combined copy is kept locally
    // and stays dirty, so the next sync carries it rather than it being lost.
    await localStore.save(toPush, sourceId: sourceId);
    return _PushOutcome(project: toPush, merged: combined);
  }

  /// Appends items to a project's archive file, creating it if need be.
  ///
  /// Returns null on success, or a message saying why not — the caller only
  /// removes them from the list once they are safely written.
  Future<String?> archiveItems(
    GitHubConfig config,
    Project project,
    List<ChecklistItem> items,
  ) async {
    if (items.isEmpty) return null;
    if (!config.isComplete) {
      return 'Connect a GitHub repo in Settings before archiving.';
    }

    final path = '${GitHubClient.archiveDir}/${project.fileSlug}.md';
    final client = _clientFactory(config);
    try {
      final existing = await client.readFile(path);
      final stamp = DateTime.now().toUtc().toIso8601String().split('T').first;

      final buffer = StringBuffer();
      if (existing == null) {
        buffer
          ..writeln('# ${project.title} — archive')
          ..writeln()
          ..writeln(
            'Completed items moved out of `projects/${project.fileSlug}.md`.',
          )
          ..writeln();
      } else {
        buffer.write(existing.content);
        if (!existing.content.endsWith('\n')) buffer.writeln();
        buffer.writeln();
      }

      buffer
        ..writeln('## Archived $stamp')
        ..writeln();
      for (final item in items) {
        buffer.write(ProjectMarkdown.serializeItem(item));
      }

      await client.writeFile(
        path: path,
        content: buffer.toString(),
        message:
            'Archive ${items.length} completed '
            '${items.length == 1 ? 'item' : 'items'} from ${project.title}',
        sha: existing?.sha,
      );
      return null;
    } on GitHubException catch (error) {
      return 'Could not write the archive: ${error.message}';
    } catch (_) {
      return 'Could not reach GitHub to write the archive.';
    } finally {
      client.dispose();
    }
  }

  /// Uploads one attachment. Errors are left to the caller, which already
  /// turns a [GitHubException] into something readable.
  /// Reads a project's canvas layout from the repo.
  ///
  /// Absent, unreadable or nonsense all mean the same thing — no layout — so a
  /// canvas whose positions cannot be read opens as the list of pictures and
  /// notes it is rather than as an error.
  Future<CanvasLayout> readLayout(GitHubConfig config, String slug) async {
    final client = _clientFactory(config);
    try {
      final file = await client.readFile(CanvasLayout.path(slug));
      if (file == null) return CanvasLayout.empty;
      return CanvasLayout.parse(file.content, sha: file.sha);
    } on GitHubException {
      return CanvasLayout.empty;
    }
  }

  /// Writes a project's canvas layout, and returns it with the SHA GitHub
  /// gave back.
  ///
  /// Last write wins, deliberately. A layout is an arrangement, not content —
  /// the pictures and the notes are in the markdown and merge the way they
  /// always did — so a rejected SHA is answered by reading the current one and
  /// writing over it rather than by asking anyone to resolve anything. The
  /// worst case is that a card someone else moved goes back where this device
  /// had it, which is a thing you can see and drag back.
  Future<CanvasLayout> writeLayout(
    GitHubConfig config,
    String slug,
    CanvasLayout layout,
  ) async {
    final client = _clientFactory(config);
    final path = CanvasLayout.path(slug);

    if (layout.isEmpty) {
      // Nothing left to arrange: take the file away rather than leave an empty
      // one implying the project still has a canvas.
      if (layout.sha != null) {
        try {
          await client.deleteFile(
            path: path,
            sha: layout.sha!,
            message: 'Remove canvas layout for $slug',
          );
        } on GitHubException {
          // It is already gone, or cannot be removed; either way there is
          // nothing here worth interrupting anyone over.
        }
      }
      return CanvasLayout.empty;
    }

    Future<String> write(String? sha) => client.writeFile(
      path: path,
      content: layout.toJsonString(),
      message: 'Update canvas layout for $slug',
      sha: sha,
    );

    try {
      return layout.copyWith(sha: await write(layout.sha));
    } on GitHubException catch (error) {
      if (error.statusCode != 409 && error.statusCode != 422) rethrow;
      final current = await client.readFile(path);
      return layout.copyWith(sha: await write(current?.sha));
    }
  }

  Future<void> uploadAttachment(
    GitHubConfig config, {
    required String path,
    required List<int> bytes,
    required String message,
  }) async {
    final client = _clientFactory(config);
    try {
      await client.writeBytes(path: path, bytes: bytes, message: message);
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
      // The project's images have nothing left referring to them.
      await _deleteAttachmentDirectory(client, project);
      await _deleteLayout(client, project);
      return null;
    } on GitHubException catch (error) {
      return 'Removed here, but GitHub still has the file: ${error.message}';
    } catch (_) {
      return 'Removed here, but GitHub could not be reached.';
    } finally {
      client.dispose();
    }
  }

  /// Removes the canvas layout belonging to a deleted project.
  ///
  /// The markdown and the attachments were already being cleaned up and this
  /// was not, so every deleted project left its arrangement behind on GitHub
  /// for good — and a project later made with the same name would silently
  /// inherit the dead one's canvases.
  ///
  /// Swallowed like the attachments, and for the same reason: the project
  /// itself is gone, and a leftover file is untidy rather than broken.
  Future<void> _deleteLayout(GitHubClient client, Project project) async {
    try {
      final path = CanvasLayout.path(project.fileSlug);
      // The folder, not the file: listing a single file gives back the file
      // rather than a listing, and what is needed here is its SHA.
      final files = await client.listDirectory(path.split('/').first);
      final sha = files[path];
      if (sha == null) return;

      await client.deleteFile(
        path: path,
        sha: sha,
        message: 'Remove the canvas layout for ${project.title}',
      );
    } catch (_) {
      // Nothing depends on this having worked.
    }
  }

  /// Removes every attachment belonging to a deleted project.
  ///
  /// Failures here are deliberately swallowed: the project file is already
  /// gone, and a leftover image is untidy rather than broken, so it is not
  /// worth reporting an error over.
  Future<void> _deleteAttachmentDirectory(
    GitHubClient client,
    Project project,
  ) async {
    try {
      final files = await client.listDirectory(
        '${GitHubClient.attachmentsDir}/${project.fileSlug}',
      );
      for (final entry in files.entries) {
        await client.deleteFile(
          path: entry.key,
          sha: entry.value,
          message: 'Remove unused attachment ${entry.key.split('/').last}',
        );
      }
    } catch (_) {
      // Left behind; the next sweep can pick it up.
    }
  }

  /// Deletes attachments of [project] that nothing in it references any more.
  ///
  /// Called after an edit, so removing an image from a note takes the file
  /// with it instead of leaving it in the repo for good.
  Future<void> pruneAttachments(GitHubConfig config, Project project) async {
    if (!config.isComplete) return;

    final referenced = <String>{};
    for (final item in project.items) {
      referenced.addAll(ProjectLinks.attachmentNames(item.notes));
    }
    referenced.addAll(ProjectLinks.attachmentNames(project.notes));

    final client = _clientFactory(config);
    try {
      final files = await client.listDirectory(
        '${GitHubClient.attachmentsDir}/${project.fileSlug}',
      );

      for (final entry in files.entries) {
        final name = entry.key.split('/').last;
        if (referenced.contains(name)) continue;

        await client.deleteFile(
          path: entry.key,
          sha: entry.value,
          message: 'Remove unused attachment $name',
        );
      }
    } catch (_) {
      // Tidying is best effort; the notes themselves are already correct.
    } finally {
      client.dispose();
    }
  }
}
