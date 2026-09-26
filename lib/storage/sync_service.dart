import '../markdown/project_links.dart';
import '../markdown/project_markdown.dart';
import '../markdown/project_merge.dart';
import '../models/checklist_item.dart';
import '../models/canvas_layout.dart';
import '../models/notes_source.dart';
import '../models/project.dart';
import '../models/sidebar_layout.dart';
import 'github_client.dart';
import 'notebook_index.dart';
import 'local_store.dart';

final _md = RegExp(r'\.md$');

String _slugOf(String path) => path.split('/').last.replaceAll(_md, '');

class SyncResult {
  const SyncResult({
    required this.projects,
    this.error,
    this.pending = 0,
    this.merged = const [],
    this.layouts = const {},
  });

  final List<Project> projects;

  /// Human-readable reason the sync did not fully succeed, if any.
  final String? error;

  /// How many projects still hold unpushed edits.
  final int pending;

  /// Titles that changed here and on GitHub at the same time and were
  /// combined. Worth mentioning, but nothing to answer.
  final List<String> merged;

  /// Arrangements that arrived with this sync, keyed by project slug — the
  /// difference between a section being a canvas and being a bullet list.
  final Map<String, CanvasLayout> layouts;

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

      // Pushed during this sync, and so certainly on GitHub whatever the
      // listing that follows happens to say. GitHub serves listings through a
      // cache that can be a moment behind a write, and treating "not in the
      // listing" as "deleted" for a file written seconds ago would delete
      // exactly the work somebody just did.
      final justPushed = <String>{};

      // Push anything edited offline first, so a pull cannot clobber it.
      for (final project in local.where((p) => p.dirty)) {
        justPushed.add(project.fileSlug);
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
      final listing = await client.listProjects();
      final present = listing.map((entry) => _slugOf(entry.path)).toSet();

      // A project that has gone from the repo goes from here too. It is how
      // a project deleted, or shared into another notebook, stops haunting
      // the other device: without this the desktop keeps a copy of a file
      // that no longer exists, which can never sync again and is not a copy
      // of anything.
      //
      // Only one that was known to be there: a project made here and not yet
      // pushed has never been in a listing, and dropping it would delete
      // somebody's work for the crime of being new.
      for (final slug in byslug.keys.toList()) {
        final project = byslug[slug]!;
        if (project.dirty || project.sha == null) continue;
        if (present.contains(slug) || justPushed.contains(slug)) continue;

        byslug.remove(slug);
        await localStore.delete(slug, sourceId: sourceId);
      }

      for (final entry in listing) {
        final slug = _slugOf(entry.path);
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

      final layouts = await _pullLayouts(client, projects, sourceId: sourceId);

      return SyncResult(
        projects: projects,
        error: problems.isEmpty ? null : problems.join('\n'),
        pending: projects.where((p) => p.dirty).length,
        merged: merged,
        layouts: layouts,
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

  /// Reads how the sidebar is arranged, from your own repo.
  Future<SidebarLayout> readSidebar(GitHubConfig config) async {
    if (!config.isComplete) return SidebarLayout.empty;

    final client = _clientFactory(config);
    try {
      final file = await client.readFile(SidebarLayout.path);
      if (file == null) return SidebarLayout.empty;
      return SidebarLayout.parse(file.content, sha: file.sha);
    } catch (_) {
      return SidebarLayout.empty;
    } finally {
      client.dispose();
    }
  }

  /// Writes it back, so your other devices show the same arrangement.
  ///
  /// Nothing sensitive in it — the names of your own groups and the order of
  /// your own lists — so unlike the notebooks it does not care whether the
  /// repo is private.
  /// Returns the SHA it now has, which the next write has to be sent
  /// against — without keeping it, every write after the first is refused
  /// and only the first rearrangement of a session ever left the device.
  Future<String?> writeSidebar(
    GitHubConfig config,
    SidebarLayout layout,
  ) async {
    if (!config.isComplete) return null;

    final client = _clientFactory(config);
    try {
      return await client.writeFile(
        path: SidebarLayout.path,
        content: layout.serialize(),
        message: 'Update the project list',
        sha: layout.sha,
      );
    } catch (_) {
      // The arrangement is kept on the device either way; it is not worth
      // interrupting anybody over.
      return null;
    } finally {
      client.dispose();
    }
  }

  /// Reads the shared notebooks your own repo knows about.
  ///
  /// Missing is not an error: it only means no device has written one yet.
  Future<NotebookIndex> readNotebooks(GitHubConfig config) async {
    if (!config.isComplete) return NotebookIndex.empty;

    final client = _clientFactory(config);
    try {
      final file = await client.readFile(NotebookIndex.path);
      if (file == null) return NotebookIndex.empty;
      return NotebookIndex.parse(file.content, sha: file.sha);
    } catch (_) {
      // Being offline, or anything else at all. This is a convenience — your
      // devices finding each other's notebooks — and it is never a reason to
      // fail the sync it happens inside.
      return NotebookIndex.empty;
    } finally {
      client.dispose();
    }
  }

  /// Writes the shared notebooks into your own repo, so your other devices
  /// find them — but only into a private one.
  ///
  /// A share code carries a token. Writing one into a public repo would hand
  /// the notebook to anybody who wandered past, and it is the kind of mistake
  /// that cannot be taken back once a crawler has seen it, so the repo is
  /// asked every time rather than remembered. Refusing returns a sentence for
  /// the person, not an exception: nothing is broken, one convenience is off.
  ///
  /// Returns null when it was written, or why it was not.
  Future<String?> writeNotebooks(
    GitHubConfig config,
    NotebookIndex index,
  ) async {
    if (!config.isComplete) return null;

    final client = _clientFactory(config);
    try {
      if (!await client.repoIsPrivate()) {
        return 'Your notes repo is public, so the shared notebooks are kept '
            'on this device only — the code that reaches one is a key, and a '
            'public repo would publish it. Paste the code on your other '
            'devices, or make the repo private.';
      }

      await client.writeFile(
        path: NotebookIndex.path,
        content: index.serialize(),
        message: 'Update shared notebooks',
        sha: index.sha,
      );
      return null;
    } on GitHubException catch (error) {
      return 'The shared notebooks could not be saved to your repo: '
          '${error.message}';
    } catch (_) {
      return 'The shared notebooks could not be saved to your repo.';
    } finally {
      client.dispose();
    }
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

  /// Fetches the arrangements that have changed, for the projects in hand.
  ///
  /// A canvas is a section with an arrangement beside it, and the arrangement
  /// is its own file. Sync pulled the markdown and never the arrangement, so
  /// a canvas made on the desktop arrived on the phone as what it is without
  /// one: an ordinary bullet list of pictures and notes. Everything was
  /// there; it simply was not a canvas.
  ///
  /// One listing for the whole folder, and only the files whose SHA has
  /// moved are fetched — the same bargain the projects themselves get, so
  /// checking often stays affordable.
  Future<Map<String, CanvasLayout>> _pullLayouts(
    GitHubClient client,
    List<Project> projects, {
    required String sourceId,
  }) async {
    final wanted = {for (final p in projects) CanvasLayout.path(p.fileSlug): p};
    if (wanted.isEmpty) return const {};

    final pulled = <String, CanvasLayout>{};
    try {
      final listing = await client.listDirectory(CanvasLayout.dir);

      for (final entry in listing.entries) {
        final project = wanted[entry.key];
        if (project == null) continue;

        final known = await localStore.loadLayout(
          project.fileSlug,
          sourceId: sourceId,
        );
        if (!known.isEmpty && known.sha == entry.value) continue;

        final file = await client.readFile(entry.key);
        if (file == null) continue;

        final layout = CanvasLayout.parse(file.content, sha: file.sha);
        pulled[project.slug] = layout;
        await localStore.saveLayout(
          project.fileSlug,
          layout,
          sourceId: sourceId,
        );
      }
    } catch (_) {
      // An arrangement that could not be fetched leaves the section as a
      // list, which is what it already looked like. The notes themselves are
      // the part that must not fail.
    }
    return pulled;
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
    try {
      return await _writeLayoutWith(client, path, slug, layout);
    } finally {
      client.dispose();
    }
  }

  Future<CanvasLayout> _writeLayoutWith(
    GitHubClient client,
    String path,
    String slug,
    CanvasLayout layout,
  ) async {
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

  /// Uploads one attachment. Errors are left to the caller, which already
  /// turns a [GitHubException] into something readable.
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
  ///
  /// What counts as a reference is the whole file, written out exactly as it
  /// is pushed, rather than a list of the places a picture is allowed to be.
  /// That list was items' notes and the project's own, and it was wrong: a
  /// canvas card is a bullet in a section's prose, so every picture on every
  /// canvas looked like an orphan and was deleted from the repo seconds
  /// after it was uploaded. The device that added it kept showing it from
  /// its cache, so it looked like the *other* device was broken.
  ///
  /// Reading the serialized file cannot go wrong the same way again: if a
  /// picture is anywhere the file can hold one, it is referenced. Deleting
  /// somebody's picture is unrecoverable, and leaving a stray file costs a
  /// few kilobytes, so this errs the only direction it can afford to.
  ///
  /// [recover] is asked for the bytes of a picture the file refers to that is
  /// not in the repo, so a device still holding it can put it back. That is
  /// how a picture deleted by the old sweep returns: the phone that added it
  /// still has it cached, and the desktop that only ever saw a broken square
  /// gets it on the next sync.
  Future<void> pruneAttachments(
    GitHubConfig config,
    Project project, {
    Future<List<int>?> Function(String repoPath)? recover,
  }) async {
    if (!config.isComplete) return;

    final referenced = ProjectLinks.attachmentNames(
      ProjectMarkdown.serialize(project),
    );

    final client = _clientFactory(config);
    try {
      final folder = '${GitHubClient.attachmentsDir}/${project.fileSlug}';
      final files = await client.listDirectory(folder);
      final present = files.keys.map((path) => path.split('/').last).toSet();

      for (final entry in files.entries) {
        final name = entry.key.split('/').last;
        if (referenced.contains(name)) continue;

        await client.deleteFile(
          path: entry.key,
          sha: entry.value,
          message: 'Remove unused attachment $name',
        );
      }

      if (recover == null) return;
      for (final name in referenced) {
        if (present.contains(name)) continue;

        final bytes = await recover('$folder/$name');
        if (bytes == null) continue;

        await client.writeBytes(
          path: '$folder/$name',
          bytes: bytes,
          message: 'Restore missing attachment $name',
        );
      }
    } catch (_) {
      // Tidying is best effort; the notes themselves are already correct.
    } finally {
      client.dispose();
    }
  }
}
