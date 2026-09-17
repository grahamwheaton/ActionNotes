import 'dart:async';

import 'package:flutter/material.dart';

import '../markdown/project_links.dart';
import '../markdown/project_merge.dart';
import '../models/checklist_item.dart';
import '../models/project.dart';
import '../storage/attachment_store.dart';
import '../storage/github_client.dart';
import '../storage/image_encoder.dart';
import '../storage/local_store.dart';
import '../storage/settings_store.dart';
import '../storage/sync_service.dart';

/// Which item's notes the desktop layout is editing in its detail pane.
///
/// The index is into the project's own item list, which is what every other
/// item operation takes; [NoteTarget] exists so the pane can tell "no note
/// open" from "the first item's note".
class NoteTarget {
  const NoteTarget(this.slug, this.index);

  final String slug;
  final int index;

  @override
  bool operator ==(Object other) =>
      other is NoteTarget && other.slug == slug && other.index == index;

  @override
  int get hashCode => Object.hash(slug, index);
}

/// Single source of truth for the UI.
///
/// Every mutation writes to the local cache immediately and schedules a push,
/// so the UI never waits on the network to feel responsive.
class AppState extends ChangeNotifier {
  AppState({
    LocalStore? localStore,
    SettingsStore? settingsStore,
    SyncService? syncService,
    AttachmentStore? attachmentStore,
    Duration pushDelay = defaultPushDelay,
    Duration syncInterval = defaultSyncInterval,
  })  : _localStore = localStore ?? LocalStore(),
        _settingsStore = settingsStore ?? SettingsStore(),
        _pushDelay = pushDelay,
        _syncInterval = syncInterval,
        attachments = attachmentStore ?? AttachmentStore() {
    _syncService = syncService ?? SyncService(localStore: _localStore);
  }

  static const defaultPushDelay = Duration(seconds: 2);

  /// How often to look for changes made elsewhere while the app is open.
  /// Often enough that two devices feel like one, rarely enough that it is
  /// not a battery or rate-limit problem.
  static const defaultSyncInterval = Duration(seconds: 45);

  /// How long an edit settles before it is pushed. A test shortens it rather
  /// than waiting two seconds per edit.
  final Duration _pushDelay;
  final Duration _syncInterval;
  Timer? _watch;

  final LocalStore _localStore;
  final SettingsStore _settingsStore;

  /// Exposed so note rendering can resolve image references.
  final AttachmentStore attachments;
  late final SyncService _syncService;

  final Map<String, Timer> _pendingPushes = {};

  /// Projects with a push in flight, so a second one waits rather than racing
  /// it with a SHA that is about to be out of date.
  final Set<String> _pushing = {};

  List<Project> _projects = [];
  GitHubConfig _config = const GitHubConfig(owner: '', repo: '', branch: 'main', token: '');
  bool _loading = true;
  bool _syncing = false;
  String? _message;
  String? _selectedSlug;
  NoteTarget? _openNote;
  NoteTarget? _revealed;
  ThemeMode _themeMode = ThemeMode.system;
  List<ProjectConflict> _conflicts = [];

  List<Project> get projects => List.unmodifiable(_projects);
  GitHubConfig get config => _config;
  bool get loading => _loading;
  bool get syncing => _syncing;
  String? get message => _message;
  bool get isConfigured => _config.isComplete;
  int get pendingCount => _projects.where((p) => p.dirty).length;

  /// Projects that changed both here and on GitHub, awaiting a decision.
  List<ProjectConflict> get conflicts => List.unmodifiable(_conflicts);

  ProjectConflict? conflictFor(String slug) {
    for (final conflict in _conflicts) {
      if (conflict.slug == slug) return conflict;
    }
    return null;
  }

  /// Which project the desktop layout is showing in its detail pane.
  String? get selectedSlug => _selectedSlug;

  void select(String? slug) {
    if (_selectedSlug == slug) return;
    _selectedSlug = slug;
    // A note belongs to the project it was opened from, and its index means
    // nothing in another one.
    _openNote = null;
    notifyListeners();
  }

  /// An item a search asked to be shown, for the list to scroll to and mark
  /// for a moment. Cleared as soon as the list has taken it, so coming back
  /// to a project later does not flash a line again.
  NoteTarget? get revealed => _revealed;

  void revealItem(String slug, int index) {
    _revealed = NoteTarget(slug, index);
    notifyListeners();
  }

  /// Called by the list once it has scrolled to it.
  void clearRevealed() {
    if (_revealed == null) return;
    _revealed = null;
    notifyListeners();
  }

  /// The note being edited beside the sidebar, or null when the pane is
  /// showing the checklist. Only the wide layout sets this; a phone pushes
  /// the editor as a screen instead.
  NoteTarget? get openNote => _openNote;

  void showNote(String slug, int index) {
    final target = NoteTarget(slug, index);
    if (_openNote == target) return;
    _openNote = target;
    _selectedSlug = slug;
    notifyListeners();
  }

  void hideNote() {
    if (_openNote == null) return;
    _openNote = null;
    notifyListeners();
  }

  Project? projectBySlug(String slug) {
    for (final project in _projects) {
      if (project.slug == slug) return project;
    }
    return null;
  }

  /// Light, dark, or the system's choice. Read once on start and written
  /// whenever it changes, so the override survives a restart.
  ThemeMode get themeMode => _themeMode;

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    await _settingsStore.saveThemeMode(mode);
  }

  Future<void> init() async {
    _themeMode = await _settingsStore.loadThemeMode();
    _config = await _settingsStore.load();
    _projects = await _localStore.loadAll();
    _loading = false;
    notifyListeners();

    if (_config.isComplete) unawaited(sync());
  }

  /// Starts checking for other people's changes while the app is in front.
  ///
  /// Without it a change made on the other device, or by a model editing the
  /// repo, is invisible until something local prompts a sync.
  void startWatching() {
    _watch?.cancel();
    _watch = Timer.periodic(_syncInterval, (_) {
      if (_config.isComplete && !_syncing) unawaited(sync());
    });
  }

  /// Stops it, for when the app goes to the background: a phone should not be
  /// polling GitHub in someone's pocket.
  void stopWatching() {
    _watch?.cancel();
    _watch = null;
  }

  Future<void> sync() async {
    if (_syncing) return;
    _syncing = true;
    notifyListeners();

    // A push already in flight holds the SHA this sync would write against,
    // so let it land first rather than racing it into a conflict.
    for (var waited = 0; _pushing.isNotEmpty && waited < 30; waited++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    // What was in hand when the sync started. The service works from the
    // copies it loaded then, so this is how a project edited while it ran can
    // be told from one it left alone.
    final before = {for (final project in _projects) project.slug: project};

    final result = await _syncService.sync(_config);
    _projects = _reconcile(before, result.projects);
    _message = result.error;
    _conflicts = result.conflicts;
    _syncing = false;
    notifyListeners();
  }

  /// Folds a sync's answer into what is on screen, keeping anything edited
  /// while it was running.
  ///
  /// Taking the result wholesale would replace such a project with its own
  /// older self: the edit disappears from the list, and the SHA it carries is
  /// the one from before the sync wrote the file — which the next push sends,
  /// and GitHub refuses as a conflict nobody caused.
  List<Project> _reconcile(
    Map<String, Project> before,
    List<Project> synced,
  ) {
    final live = {for (final project in _projects) project.slug: project};
    final reconciled = <Project>[];

    for (final project in synced) {
      final current = live.remove(project.slug);
      final start = before[project.slug];

      // Every edit stamps a new time, so a changed stamp is an edit; the
      // dirty check is there for the edit that lands inside the same
      // millisecond the sync started.
      final editedDuringSync = current != null &&
          (start == null ||
              current.updated != start.updated ||
              (current.dirty && !start.dirty));

      // Keep the newer content, but take the SHA the sync learned: that is
      // what the file on GitHub has now, so it is what the next push has to
      // be sent against.
      reconciled.add(editedDuringSync
          ? current.copyWith(sha: project.sha, dirty: true)
          : project);
    }

    // A project created while the sync was running is not in its answer at
    // all, and must not be dropped for it.
    reconciled.addAll(live.values);

    return reconciled
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }

  /// Settles a conflict and clears it, so the project can sync again.
  Future<void> resolveConflict(
    String slug,
    ConflictResolution resolution,
  ) async {
    final conflict = conflictFor(slug);
    if (conflict == null) return;

    // Cancel any queued push; it would carry the stale SHA.
    _pendingPushes.remove(slug)?.cancel();

    final settled = await _syncService.resolve(_config, conflict, resolution);

    _conflicts = _conflicts.where((c) => c.slug != slug).toList();
    _projects = [
      for (final project in _projects)
        if (project.slug == slug) settled else project,
    ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

    if (settled.dirty) {
      _message = 'Resolved "${settled.title}" here, but the push has not gone '
          'through yet — it will retry on the next sync.';
    }
    notifyListeners();
  }

  Future<void> updateConfig(GitHubConfig config) async {
    _config = config;
    await _settingsStore.save(config);
    notifyListeners();
    if (config.isComplete) await sync();
  }

  /// Checks the repo is reachable with these details. Returns null on success,
  /// or a message explaining what went wrong.
  Future<String?> testConnection(GitHubConfig config) async {
    if (!config.isComplete) return 'Fill in owner, repo, branch and token.';

    final client = GitHubClient(config);
    try {
      await client.checkAccess();
      return null;
    } on GitHubException catch (error) {
      return switch (error.statusCode) {
        401 => 'Token rejected. Check it was copied in full and has not expired.',
        403 => 'Token lacks permission for this repo. It needs Contents: Read and write.',
        // Signing in and installing the app are separate steps on GitHub, and
        // a sign-in that skipped the install lands here with a valid token
        // that can see nothing. Say so, rather than implying a typo.
        404 => 'Cannot see ${config.owner}/${config.repo}. Check the names, and '
            'that the ActionNotes app is installed on this repo — signing in '
            'does not install it, and an app installed nowhere can see '
            'nothing. Install it from its Install App tab under '
            'github.com/settings/apps.',
        _ => error.message,
      };
    } catch (_) {
      return 'Could not reach GitHub.';
    } finally {
      client.dispose();
    }
  }

  Future<Project> createProject(String title) async {
    final slug = _uniqueSlug(Project.slugify(title));
    final now = DateTime.now().toUtc();
    final project = Project(
      slug: slug,
      title: title.trim(),
      created: now,
      updated: now,
      dirty: true,
    );

    _projects = [..._projects, project]..sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
    await _localStore.save(project);
    notifyListeners();
    _schedulePush(slug);
    return project;
  }

  Future<void> renameProject(String slug, String title) =>
      _mutate(slug, (project) => project.copyWith(title: title.trim()));

  /// Adds an item at the top, where it can be seen — the list is read
  /// newest-first, and the file keeps that same order.
  Future<void> addItem(String slug, String text, {bool starred = false}) =>
      _mutate(
        slug,
        (project) => project.copyWith(
          items: [
            ChecklistItem(text: text.trim(), starred: starred),
            ...project.items,
          ],
        ),
      );

  Future<void> toggleItem(String slug, int index) => _mutate(slug, (project) {
        final items = [...project.items];
        items[index] = items[index].copyWith(done: !items[index].done);
        return project.copyWith(items: items);
      });

  Future<void> editItem(String slug, int index, String text) =>
      _mutate(slug, (project) {
        final items = [...project.items];
        items[index] = items[index].copyWith(text: text.trim());
        return project.copyWith(items: items);
      });

  Future<void> toggleStar(String slug, int index) => _mutate(slug, (project) {
        final items = [...project.items];
        items[index] = items[index].copyWith(starred: !items[index].starred);
        return project.copyWith(items: items);
      });

  Future<void> setItemNotes(String slug, int index, String notes) =>
      _mutate(slug, (project) {
        final items = [...project.items];
        items[index] = items[index].copyWith(notes: notes.trim());
        return project.copyWith(items: items);
      });

  /// Uploads [bytes] as an attachment on [slug] and returns the markdown
  /// reference to paste into a note, or null with a message set on failure.
  Future<String?> attachImage(
    String slug, {
    required String fileName,
    required List<int> bytes,
  }) async {
    if (!_config.isComplete) {
      _message = 'Connect a GitHub repo in Settings before attaching images.';
      notifyListeners();
      return null;
    }

    final project = projectBySlug(slug);
    if (project == null) return null;

    // Names already referenced by this project's notes, so a second upload of
    // the same filename does not overwrite the first.
    final taken = <String>{};
    for (final item in project.items) {
      for (final match
          in RegExp(r'attachments/[^/]+/([^)\s]+)').allMatches(item.notes)) {
        taken.add(match.group(1)!);
      }
    }

    // The clipboard hands over bitmaps on Windows, so normalise before
    // naming: a file called .png has to actually be one.
    final encoded = ImageEncoder.prepare(fileName, bytes);
    final name = AttachmentStore.uniqueFileName(encoded.fileName, taken);
    final repoPath = AttachmentStore.repoPath(slug, name);

    try {
      await _syncService.uploadAttachment(
        _config,
        path: repoPath,
        bytes: encoded.bytes,
        message: 'Add attachment $name to ${project.title}',
      );
      // Cache it so the note renders without a round trip.
      await attachments.save(repoPath, encoded.bytes);
      return '![$name](${AttachmentStore.markdownPath(slug, name)})';
    } on GitHubException catch (error) {
      _message = 'Could not upload the image: ${error.message}';
      notifyListeners();
      return null;
    } catch (_) {
      _message = 'Could not reach GitHub to upload the image.';
      notifyListeners();
      return null;
    }
  }

  /// Moves an item to another project, notes and attachments included.
  ///
  /// The attachments are the reason this is not two list edits: a note refers
  /// to `../attachments/<slug>/file`, and the tidy-up that follows a push
  /// deletes any file the project no longer mentions. Leaving the references
  /// pointing at the old project would have its images deleted underneath it,
  /// so each one is copied across and the references rewritten first. If a
  /// copy cannot be made the move does not happen, which is better than a
  /// move that loses the pictures.
  ///
  /// Returns null on success, or a message saying why not.
  Future<String?> moveItem(String fromSlug, int index, String toSlug) async {
    if (fromSlug == toSlug) return null;

    final from = projectBySlug(fromSlug);
    final to = projectBySlug(toSlug);
    if (from == null || to == null) return 'That project is no longer here.';
    if (index >= from.items.length) return 'That item is no longer here.';

    final item = from.items[index];

    // Names already used in the target, so a copy cannot overwrite one of its
    // own images.
    final taken = <String>{};
    for (final existing in to.items) {
      taken.addAll(ProjectLinks.attachmentNames(existing.notes));
    }

    var notes = item.notes;
    for (final name in ProjectLinks.attachmentNames(item.notes)) {
      final copied = await _copyAttachment(
        name: name,
        fromSlug: fromSlug,
        toSlug: toSlug,
        taken: taken,
      );
      if (copied == null) {
        return 'Could not copy "$name" to ${to.title}, so nothing was moved.';
      }
      taken.add(copied);
      notes = notes.replaceAll(
        AttachmentStore.markdownPath(fromSlug, name),
        AttachmentStore.markdownPath(toSlug, copied),
      );
    }

    // The note open on the source project cannot be trusted afterwards, for
    // the same reason a removal closes it: the indexes shift.
    if (_openNote?.slug == fromSlug) _openNote = null;

    await _mutate(fromSlug, (project) {
      final items = [...project.items]..removeAt(index);
      return project.copyWith(items: items);
    });
    await _mutate(
      toSlug,
      (project) => project.copyWith(
        items: [item.copyWith(notes: notes), ...project.items],
      ),
    );
    return null;
  }

  /// Copies one attachment into another project's folder, returning the name
  /// it was given, or null if it could not be copied.
  Future<String?> _copyAttachment({
    required String name,
    required String fromSlug,
    required String toSlug,
    required Set<String> taken,
  }) async {
    try {
      final bytes = await attachments.bytesFor(
        AttachmentStore.repoPath(fromSlug, name),
        _config,
      );
      if (bytes == null) return null;

      final copied = AttachmentStore.uniqueFileName(name, taken);
      final path = AttachmentStore.repoPath(toSlug, copied);
      await _syncService.uploadAttachment(
        _config,
        path: path,
        bytes: bytes,
        message: 'Copy attachment $copied for a moved item',
      );
      await attachments.save(path, bytes);
      return copied;
    } catch (_) {
      return null;
    }
  }

  Future<void> removeItem(String slug, int index) {
    // Removing an item shifts the indexes after it, so a note open on this
    // project can no longer be trusted to point at the item it was opened on.
    if (_openNote?.slug == slug) _openNote = null;

    return _mutate(slug, (project) {
      final items = [...project.items]..removeAt(index);
      return project.copyWith(items: items);
    });
  }

  /// Reorders the items occupying [slots], which are positions in the
  /// project's own item list, ascending. [newIndex] counts within [slots] and
  /// is the destination index — what onReorderItem already gives us, so no
  /// off-by-one adjustment is needed here.
  ///
  /// The view passes the slots it is actually showing, so dragging within one
  /// group never disturbs items in another — a completed item, or an
  /// unstarred one, stays where it is in the file.
  Future<void> reorderSlots(
    String slug,
    List<int> slots,
    int oldIndex,
    int newIndex,
  ) =>
      _mutate(slug, (project) {
        final picked = [for (final slot in slots) project.items[slot]];
        picked.insert(newIndex, picked.removeAt(oldIndex));

        final items = [...project.items];
        for (var i = 0; i < slots.length; i++) {
          items[slots[i]] = picked[i];
        }
        return project.copyWith(items: items);
      });

  /// Moves completed items out of the list and into `archive/<slug>.md`.
  ///
  /// It used to delete them, which is the one thing a checklist should not do
  /// to something you finished — and in my own notes repo, the one thing the
  /// working agreement forbids. They are written to the archive first and
  /// only then taken out of the list, so a failure leaves the list as it was.
  ///
  /// Returns null on success, or a message saying why nothing was archived.
  Future<String?> archiveCompleted(String slug) async {
    final project = projectBySlug(slug);
    if (project == null) return null;

    final done = project.items.where((item) => item.done).toList();
    if (done.isEmpty) return 'Nothing is completed yet.';

    final problem = await _syncService.archiveItems(_config, project, done);
    if (problem != null) return problem;

    await _mutate(
      slug,
      (current) => current.copyWith(
        items: current.items.where((item) => !item.done).toList(),
      ),
    );
    return null;
  }

  Future<void> setNotes(String slug, String notes) =>
      _mutate(slug, (project) => project.copyWith(notes: notes));

  Future<void> deleteProject(String slug) async {
    final project = projectBySlug(slug);
    if (project == null) return;

    _pendingPushes.remove(slug)?.cancel();
    if (_selectedSlug == slug) _selectedSlug = null;
    if (_openNote?.slug == slug) _openNote = null;
    _projects = _projects.where((p) => p.slug != slug).toList();
    await _localStore.delete(slug);
    notifyListeners();

    final problem = await _syncService.deleteRemote(_config, project);
    if (problem != null) {
      _message = problem;
      notifyListeners();
    }
  }

  void dismissMessage() {
    if (_message == null) return;
    _message = null;
    notifyListeners();
  }

  Future<void> _mutate(String slug, Project Function(Project) change) async {
    final current = projectBySlug(slug);
    if (current == null) return;

    final updated = change(current).copyWith(
      updated: DateTime.now().toUtc(),
      dirty: true,
    );

    _projects = _projects.map((p) => p.slug == slug ? updated : p).toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    await _localStore.save(updated);
    notifyListeners();
    _schedulePush(slug);
  }

  /// Coalesces rapid edits into one commit, so ticking five boxes in a row
  /// does not produce five commits.
  void _schedulePush(String slug) {
    if (!_config.isComplete) return;

    _pendingPushes.remove(slug)?.cancel();
    _pendingPushes[slug] = Timer(_pushDelay, () => _pushNow(slug));
  }

  /// Pushes one project, one at a time.
  ///
  /// GitHub accepts a write only against the SHA the file currently has, so
  /// two pushes of the same project must not overlap: the second would send
  /// the SHA the first has already moved past, and come back as a conflict
  /// nobody caused. A push arriving while one is in flight waits instead, and
  /// goes out afterwards with the SHA that one brought back.
  Future<void> _pushNow(String slug) async {
    _pendingPushes.remove(slug);

    // A sync pushes the dirty projects itself, so pushing during one would be
    // the same two-writes-one-SHA race from the other direction.
    if (_syncing) {
      _schedulePush(slug);
      return;
    }

    if (_pushing.contains(slug)) {
      _schedulePush(slug);
      return;
    }

    final project = projectBySlug(slug);
    if (project == null || !project.dirty) return;

    _pushing.add(slug);
    final Project pushed;
    try {
      pushed = await _syncService.push(_config, project);
    } finally {
      _pushing.remove(slug);
    }

    if (pushed.dirty) return; // Still pending; the next sync will retry.

    // An image dropped from a note leaves its file behind, so tidy up once
    // the note itself has landed.
    unawaited(_syncService.pruneAttachments(_config, pushed));

    final latest = projectBySlug(slug);
    if (latest == null) return;

    // The write landed, so GitHub's copy has this SHA whatever has been
    // edited here since. Keeping the old one is what made a later push look
    // like a conflict. What the edits do change is whether there is still
    // something to send.
    final editedWhilePushing = latest.updated != project.updated;
    final settled = latest.copyWith(sha: pushed.sha, dirty: editedWhilePushing);

    _projects = _projects.map((p) => p.slug == slug ? settled : p).toList();
    await _localStore.save(settled);
    notifyListeners();

    if (editedWhilePushing) _schedulePush(slug);
  }

  String _uniqueSlug(String base) {
    final taken = _projects.map((p) => p.slug).toSet();
    if (!taken.contains(base)) return base;
    var suffix = 2;
    while (taken.contains('$base-$suffix')) {
      suffix++;
    }
    return '$base-$suffix';
  }

  @override
  void dispose() {
    stopWatching();
    for (final timer in _pendingPushes.values) {
      timer.cancel();
    }
    _pendingPushes.clear();
    super.dispose();
  }
}
