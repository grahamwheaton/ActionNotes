import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../markdown/canvas_cards.dart';
import '../markdown/canvas_placement.dart';
import '../markdown/project_links.dart';
import '../markdown/project_merge.dart';
import '../models/canvas_layout.dart';
import '../models/checklist_item.dart';
import '../models/project.dart';
import '../storage/attachment_store.dart';
import '../storage/github_client.dart';
import '../storage/image_encoder.dart';
import '../storage/local_store.dart';
import '../storage/settings_store.dart';
import '../storage/sync_service.dart';
import '../storage/update_check.dart';

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
    UpdateCheck? updateCheck,
  }) : _updateCheck = updateCheck,
       _localStore = localStore ?? LocalStore(),
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

  /// Left null in tests that do not care, so nothing reaches the network for
  /// an update nobody asked about.
  final UpdateCheck? _updateCheck;
  AvailableUpdate? _update;
  bool _checkingUpdate = false;

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
  GitHubConfig _config = const GitHubConfig(
    owner: '',
    repo: '',
    branch: 'main',
    token: '',
  );
  bool _loading = true;
  bool _syncing = false;
  String? _message;
  String? _selectedSlug;
  NoteTarget? _openNote;
  NoteTarget? _revealed;
  DateTime? _lastSynced;
  String? _login;
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

  /// A newer release than the running build, once asked for. Null means
  /// either "up to date" or "not asked", which the UI treats the same: it
  /// only ever shows something when there is something to show.
  AvailableUpdate? get update => _update;
  bool get checkingUpdate => _checkingUpdate;

  /// Asks GitHub for the latest release and compares it with the running
  /// build. Silent about failure: a version check is a convenience.
  Future<AvailableUpdate?> checkForUpdate() async {
    final checker = _updateCheck;
    if (checker == null || _checkingUpdate) return _update;

    _checkingUpdate = true;
    notifyListeners();
    try {
      final info = await PackageInfo.fromPlatform();
      _update = await checker.latest(info.version);
    } catch (_) {
      _update = null;
    } finally {
      _checkingUpdate = false;
      notifyListeners();
    }
    return _update;
  }

  /// Stops the banner offering the same version again.
  void dismissUpdate() {
    if (_update == null) return;
    _update = null;
    notifyListeners();
  }

  /// When the app last heard from GitHub, or null if it has not yet. Shown
  /// in the sidebar, because a list is only as trustworthy as its last sync —
  /// especially on a phone that has been in a pocket.
  DateTime? get lastSynced => _lastSynced;

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

  /// Who a message in a note is signed as: the signed-in account if there is
  /// one, the repo owner otherwise, and a plain fallback if neither — a note
  /// should still be able to hold a conversation before anyone has signed in.
  String get me {
    final login = _login;
    if (login != null && login.isNotEmpty) return login;
    if (_config.owner.isNotEmpty) return _config.owner;
    return 'me';
  }

  /// Remembers the signed-in account's name, so notes can be signed with it.
  Future<void> setLogin(String? login) async {
    _login = login;
    notifyListeners();
    await _settingsStore.saveLogin(login);
  }

  Future<void> init() async {
    _themeMode = await _settingsStore.loadThemeMode();
    _login = await _settingsStore.loadLogin();
    _config = await _settingsStore.load();
    _projects = await _localStore.loadAll();
    for (final project in _projects) {
      await _loadLayout(project.slug);
    }
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
    // Only a sync that actually reached GitHub counts as having heard from
    // it: saying "synced a minute ago" after a failed attempt would be worse
    // than saying nothing.
    if (result.error == null) _lastSynced = DateTime.now();
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
  List<Project> _reconcile(Map<String, Project> before, List<Project> synced) {
    final live = {for (final project in _projects) project.slug: project};
    final reconciled = <Project>[];

    for (final project in synced) {
      final current = live.remove(project.slug);
      final start = before[project.slug];

      // Every edit stamps a new time, so a changed stamp is an edit; the
      // dirty check is there for the edit that lands inside the same
      // millisecond the sync started.
      final editedDuringSync =
          current != null &&
          (start == null ||
              current.updated != start.updated ||
              (current.dirty && !start.dirty));

      // Keep the newer content, but take the SHA the sync learned: that is
      // what the file on GitHub has now, so it is what the next push has to
      // be sent against.
      reconciled.add(
        editedDuringSync
            ? current.copyWith(sha: project.sha, dirty: true)
            : project,
      );
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
      _message =
          'Resolved "${settled.title}" here, but the push has not gone '
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
        401 =>
          'Token rejected. Check it was copied in full and has not expired.',
        403 =>
          'Token lacks permission for this repo. It needs Contents: Read and write.',
        // Signing in and installing the app are separate steps on GitHub, and
        // a sign-in that skipped the install lands here with a valid token
        // that can see nothing. Say so, rather than implying a typo.
        404 =>
          'Cannot see ${config.owner}/${config.repo}. Check the names, and '
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

    _projects = [..._projects, project]
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    await _localStore.save(project);
    notifyListeners();
    _schedulePush(slug);
    return project;
  }

  Future<void> renameProject(String slug, String title) =>
      _mutate(slug, (project) => project.copyWith(title: title.trim()));

  /// Adds an item at the top, where it can be seen — the list is read
  /// newest-first, and the file keeps that same order.
  ///
  /// [block] names the `##` section it belongs to. Within a block the new item
  /// goes above that block's others rather than above the whole project, so it
  /// appears where it was added.
  Future<void> addItem(
    String slug,
    String text, {
    bool starred = false,
    String? block,
  }) => _mutate(slug, (project) {
    final item = ChecklistItem(
      text: text.trim(),
      starred: starred,
      block: block,
    );
    if (block == null) return project.copyWith(items: [item, ...project.items]);

    final items = [...project.items];
    final at = items.indexWhere((existing) => existing.block == block);
    items.insert(at < 0 ? items.length : at, item);
    return project.copyWith(items: items);
  });

  /// Adds a `##` section. A repeated name is left alone rather than making a
  /// second block that could not be told from the first.
  Future<void> addBlock(String slug, String title) => _mutate(slug, (project) {
    final name = title.trim();
    if (name.isEmpty || project.blocks.any((b) => b.title == name)) {
      return project;
    }
    return project.copyWith(
      blocks: [
        ...project.blocks,
        ProjectBlock(title: name),
      ],
    );
  });

  /// Moves a `##` section, and the items under it, to another place in the
  /// project.
  ///
  /// The flat item list is rebuilt to match, so the order on screen, the order
  /// in the file and the order of the indices everything else uses stay one
  /// order rather than three.
  Future<void> reorderBlocks(String slug, int oldIndex, int newIndex) =>
      _mutate(slug, (project) {
        final blocks = [...project.blocks];
        if (oldIndex < 0 || oldIndex >= blocks.length) return project;

        // A list that reorders downwards reports the index the row will sit
        // at once it has been taken out, so close the gap first.
        var target = newIndex;
        if (target > oldIndex) target -= 1;
        target = target.clamp(0, blocks.length - 1);
        if (target == oldIndex) return project;

        blocks.insert(target, blocks.removeAt(oldIndex));

        return project.copyWith(
          blocks: blocks,
          items: [
            ...project.itemsIn(null),
            for (final block in blocks) ...project.itemsIn(block.title),
          ],
        );
      });

  /// Removes a `##` section, its items and its prose.
  ///
  /// The one place in the app that deletes several things at once, so the
  /// caller asks first. Its canvas goes too, since a layout for a heading that
  /// no longer exists would sit in the file for ever.
  Future<void> deleteBlock(String slug, String title) async {
    final layout = layoutFor(slug);
    if (layout.isCanvas(title)) {
      _layouts[slug] = layout.withoutSection(title);
      unawaited(_pushLayout(slug));
    }

    await _mutate(
      slug,
      (project) => project.copyWith(
        blocks: [
          for (final block in project.blocks)
            if (block.title != title) block,
        ],
        items: [
          for (final item in project.items)
            if (item.block != title) item,
        ],
      ),
    );
  }

  Future<void> setBlockBody(String slug, String title, String body) =>
      _mutate(slug, (project) {
        final blocks = [
          for (final block in project.blocks)
            block.title == title ? block.copyWith(body: body) : block,
        ];
        return project.copyWith(blocks: blocks);
      });

  /// Renames a section, carrying its items with it — they name their block, so
  /// renaming one without the other would orphan them.
  Future<void> renameBlock(String slug, String from, String to) =>
      _mutate(slug, (project) {
        final name = to.trim();
        if (name.isEmpty || name == from) return project;
        if (project.blocks.any((block) => block.title == name)) return project;

        // The canvas is keyed by the section's name, so it has to follow or
        // it is left pointing at a heading that has gone.
        _renameCanvasSection(slug, from, name);

        return project.copyWith(
          blocks: [
            for (final block in project.blocks)
              block.title == from ? block.copyWith(title: name) : block,
          ],
          items: [
            for (final item in project.items)
              item.block == from ? item.copyWith(block: name) : item,
          ],
        );
      });

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
      for (final match in RegExp(
        r'attachments/[^/]+/([^)\s]+)',
      ).allMatches(item.notes)) {
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
        items: [
          item.copyWith(notes: notes),
          ...project.items,
        ],
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
  ) => _mutate(slug, (project) {
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

  // --- Canvases -----------------------------------------------------------
  //
  // A canvas's content is the section's markdown, the same as any other
  // section. Only the arrangement lives here, in a file beside the project,
  // and it is the layout that says which sections are canvases at all — so a
  // project with no layout has no canvases and shows its sections as notes.

  final Map<String, CanvasLayout> _layouts = {};

  /// What a canvas looked like before each of the last few changes, and what
  /// was undone from it.
  ///
  /// A canvas is the one place in this app where a single action can rearrange
  /// a great deal of careful work — packing a board, or aligning the wrong
  /// selection — and where the result is a picture rather than a list, so
  /// putting it back by hand is not really possible. Both files are captured,
  /// the markdown and the arrangement, so adding and deleting cards can be
  /// taken back as well as moving them.
  final Map<String, List<CanvasStep>> _canvasUndo = {};
  final Map<String, List<CanvasStep>> _canvasRedo = {};

  static const _canvasHistoryDepth = 60;

  String _historyKey(String slug, String section) => '$slug\u0000$section';

  bool canUndoCanvas(String slug, String section) =>
      _canvasUndo[_historyKey(slug, section)]?.isNotEmpty ?? false;

  bool canRedoCanvas(String slug, String section) =>
      _canvasRedo[_historyKey(slug, section)]?.isNotEmpty ?? false;

  /// The canvas as it stands, for the history to hold on to.
  CanvasStep? _canvasStep(String slug, String section) {
    final project = projectBySlug(slug);
    if (project == null) return null;

    final block = project.blocks.firstWhere(
      (block) => block.title == section,
      orElse: () => const ProjectBlock(title: ''),
    );
    if (block.title.isEmpty) return null;

    return CanvasStep(
      body: block.body,
      spots: List.unmodifiable(layoutFor(slug).spotsFor(section)),
    );
  }

  /// Remembers the canvas before something changes it.
  void _rememberCanvas(String slug, String section) {
    final step = _canvasStep(slug, section);
    if (step == null) return;

    final key = _historyKey(slug, section);
    final history = _canvasUndo.putIfAbsent(key, () => []);
    // Nothing changed: a repeated identical step would make undo look broken
    // by appearing to do nothing.
    if (history.isNotEmpty && history.last == step) return;

    history.add(step);
    if (history.length > _canvasHistoryDepth) history.removeAt(0);
    // A fresh change is a new branch, so what was undone is no longer ahead.
    _canvasRedo.remove(key);
  }

  Future<void> undoCanvas(String slug, String section) =>
      _stepCanvas(slug, section, from: _canvasUndo, to: _canvasRedo);

  Future<void> redoCanvas(String slug, String section) =>
      _stepCanvas(slug, section, from: _canvasRedo, to: _canvasUndo);

  Future<void> _stepCanvas(
    String slug,
    String section, {
    required Map<String, List<CanvasStep>> from,
    required Map<String, List<CanvasStep>> to,
  }) async {
    final key = _historyKey(slug, section);
    final history = from[key];
    if (history == null || history.isEmpty) return;

    final now = _canvasStep(slug, section);
    final step = history.removeLast();
    if (now != null) {
      (to.putIfAbsent(key, () => [])).add(now);
    }

    _layouts[slug] = layoutFor(slug).withSection(section, step.spots);
    unawaited(_pushLayout(slug));
    await setBlockBody(slug, section, step.body);
  }

  final Map<String, Timer> _layoutTimers = {};

  CanvasLayout layoutFor(String slug) => _layouts[slug] ?? CanvasLayout.empty;

  bool isCanvas(String slug, String section) =>
      layoutFor(slug).isCanvas(section);

  Future<void> _loadLayout(String slug) async {
    final layout = await _localStore.loadLayout(slug);
    if (layout.isEmpty) return;
    _layouts[slug] = layout;
    notifyListeners();
  }

  /// Turns a section into a canvas, or back into notes.
  ///
  /// Nothing is rewritten either way: the section's markdown is the same list
  /// of pictures and notes, and only whether there is an arrangement for it
  /// changes. Turning a canvas back into notes forgets where things were —
  /// which is the cost of the arrangement living in its own file, and is said
  /// plainly rather than hidden.
  /// How a canvas is drawn: its height in a project, its background, whether
  /// it keeps its own light or dark.
  CanvasSettings canvasSettings(String slug, String section) =>
      layoutFor(slug).settingsFor(section);

  Future<void> setCanvasSettings(
    String slug,
    String section,
    CanvasSettings settings,
  ) async {
    final layout = layoutFor(slug);
    if (layout.settingsFor(section) == settings) return;

    _layouts[slug] = layout.withSettings(section, settings);
    notifyListeners();
    await _pushLayout(slug);
  }

  Future<void> setCanvas(String slug, String section, bool canvas) async {
    final layout = layoutFor(slug);
    if (layout.isCanvas(section) == canvas) return;

    _layouts[slug] = canvas
        ? layout.withSection(section, const [])
        : layout.withoutSection(section);
    notifyListeners();
    await _pushLayout(slug);
  }

  /// Puts a new card on a canvas.
  ///
  /// Appended to the section's markdown as another bullet, which is all a card
  /// is — the arrangement follows on its own, since a card with no position is
  /// laid down in free space rather than on the pile.
  Future<void> addCanvasCard(
    String slug,
    String section,
    String markdown,
  ) async {
    final project = projectBySlug(slug);
    if (project == null) return;

    final block = project.blocks.firstWhere(
      (block) => block.title == section,
      orElse: () => const ProjectBlock(title: ''),
    );
    if (block.title.isEmpty) return;

    _rememberCanvas(slug, section);

    final cards = [
      ...CanvasCards.parse(block.body),
      CanvasCards.text(markdown),
    ];
    await setBlockBody(slug, section, CanvasCards.serialize(cards));
  }

  /// Puts a card on a canvas at a given spot, rather than wherever there was
  /// room.
  ///
  /// This is how everything the side tools place arrives: a sticky note, a
  /// caption, a frame. The text is a bullet in the section's markdown like
  /// every other card, so a canvas read anywhere else is still a readable
  /// list; what sort of card it is and where it sits are the layout file's
  /// business.
  Future<void> placeCanvasCard(
    String slug,
    String section, {
    required String markdown,
    required CanvasSpot spot,
    bool behind = false,
  }) async {
    final project = projectBySlug(slug);
    if (project == null) return;

    final block = project.blocks.firstWhere(
      (block) => block.title == section,
      orElse: () => const ProjectBlock(title: ''),
    );
    if (block.title.isEmpty) return;

    _rememberCanvas(slug, section);

    final existing = CanvasPlacement.place(
      CanvasCards.parse(block.body),
      layoutFor(slug).spotsFor(section),
    );

    var z = 0;
    for (final other in existing) {
      if (behind) {
        if (other.z <= z) z = other.z - 1;
      } else if (other.z >= z) {
        z = other.z + 1;
      }
    }

    final card = CanvasCards.text(markdown);
    _layouts[slug] = layoutFor(
      slug,
    ).withSection(section, [...existing, spot.copyWith(ref: card.ref, z: z)]);
    unawaited(_pushLayout(slug));

    await setBlockBody(
      slug,
      section,
      CanvasCards.serialize([...CanvasCards.parse(block.body), card]),
    );
  }

  /// Puts a frame on a canvas: a labelled rectangle to group things inside.
  ///
  /// Behind the cards, because a frame is what the others stand on.
  Future<void> addCanvasFrame(
    String slug,
    String section, {
    String title = 'Frame',
    double x = 40,
    double y = 40,
    double width = 560,
    double height = 400,
  }) => placeCanvasCard(
    slug,
    section,
    markdown: title,
    behind: true,
    spot: CanvasSpot(
      x: x,
      y: y,
      width: width,
      height: height,
      kind: CanvasSpotKind.frame,
    ),
  );

  /// Rewrites one card's markdown, leaving where it sits alone.
  ///
  /// Renaming a frame and editing a note on the board are the same operation:
  /// a card is its markdown, and its position is somewhere else entirely.
  Future<void> setCanvasCard(
    String slug,
    String section,
    int index,
    String markdown,
  ) async {
    final project = projectBySlug(slug);
    if (project == null) return;

    final block = project.blocks.firstWhere(
      (block) => block.title == section,
      orElse: () => const ProjectBlock(title: ''),
    );
    if (block.title.isEmpty) return;

    final cards = CanvasCards.parse(block.body);
    if (index < 0 || index >= cards.length) return;
    if (markdown.trim().isEmpty) return;

    _rememberCanvas(slug, section);
    cards[index] = CanvasCards.text(markdown);

    // The position points at the card by what the card said, so a renamed
    // card takes its position's ref with it rather than looking like a new
    // one that has never been placed.
    final spots = [...layoutFor(slug).spotsFor(section)];
    if (index < spots.length) {
      spots[index] = spots[index].copyWith(ref: cards[index].ref);
      _layouts[slug] = layoutFor(slug).withSection(section, spots);
      unawaited(_pushLayout(slug));
    }

    await setBlockBody(slug, section, CanvasCards.serialize(cards));
  }

  /// Takes a card off a canvas, which is to say out of the section's markdown.
  ///
  /// The position goes with it: a spot whose card has gone would be dropped
  /// the next time the two were paired anyway, and leaving it would shift
  /// every later card along by one until it was.
  Future<void> removeCanvasCard(String slug, String section, int index) async {
    final project = projectBySlug(slug);
    if (project == null) return;

    final block = project.blocks.firstWhere(
      (block) => block.title == section,
      orElse: () => const ProjectBlock(title: ''),
    );
    if (block.title.isEmpty) return;

    final cards = CanvasCards.parse(block.body);
    if (index < 0 || index >= cards.length) return;
    _rememberCanvas(slug, section);
    cards.removeAt(index);

    final spots = [...layoutFor(slug).spotsFor(section)];
    if (index < spots.length) {
      spots.removeAt(index);
      _layouts[slug] = layoutFor(slug).withSection(section, spots);
      unawaited(_pushLayout(slug));
    }

    await setBlockBody(slug, section, CanvasCards.serialize(cards));
  }

  /// Puts a copy of a card on the canvas beside the original.
  ///
  /// Both the markdown and the arrangement gain an entry, so the copy is a
  /// card in its own right rather than the same one drawn twice.
  Future<void> duplicateCanvasCard(
    String slug,
    String section,
    int index,
  ) async {
    final project = projectBySlug(slug);
    if (project == null) return;

    final block = project.blocks.firstWhere(
      (block) => block.title == section,
      orElse: () => const ProjectBlock(title: ''),
    );
    if (block.title.isEmpty) return;

    final cards = CanvasCards.parse(block.body);
    if (index < 0 || index >= cards.length) return;
    _rememberCanvas(slug, section);
    cards.insert(index + 1, cards[index]);

    final spots = [...layoutFor(slug).spotsFor(section)];
    if (index < spots.length) {
      final from = spots[index];
      spots.insert(
        index + 1,
        // Offset a little, so the copy is visibly a second card rather than
        // one exactly on top of another.
        from.copyWith(x: from.x + 24, y: from.y + 24, locked: false),
      );
      _layouts[slug] = layoutFor(slug).withSection(section, spots);
      unawaited(_pushLayout(slug));
    }

    await setBlockBody(slug, section, CanvasCards.serialize(cards));
  }

  Future<void> setCanvasSpots(
    String slug,
    String section,
    List<CanvasSpot> spots, {
    bool remember = true,
  }) async {
    if (remember) _rememberCanvas(slug, section);
    _layouts[slug] = layoutFor(slug).withSection(section, spots);
    notifyListeners();

    // Settled for a moment first: dragging a card across a canvas would
    // otherwise be a commit per frame.
    _layoutTimers[slug]?.cancel();
    _layoutTimers[slug] = Timer(_pushDelay, () => _pushLayout(slug));
  }

  Future<void> _renameCanvasSection(String slug, String from, String to) async {
    final layout = layoutFor(slug);
    if (!layout.isCanvas(from)) return;
    _layouts[slug] = layout.renameSection(from, to);
    await _pushLayout(slug);
  }

  Future<void> _pushLayout(String slug) async {
    _layoutTimers.remove(slug)?.cancel();
    final layout = layoutFor(slug);
    await _localStore.saveLayout(slug, layout);
    if (!_config.isComplete) return;

    try {
      final pushed = await _syncService.writeLayout(_config, slug, layout);
      // Adopt the SHA whatever else has happened in the meantime, the same as
      // a project push does: throwing it away is what made every later write
      // fail against a SHA GitHub had already moved past.
      _layouts[slug] = layoutFor(slug).copyWith(sha: pushed.sha);
      await _localStore.saveLayout(slug, _layouts[slug]!);
    } catch (_) {
      // An arrangement is worth no interruption. It is saved on the device and
      // the next change will try again.
    }
  }

  Future<void> setNotes(String slug, String notes) =>
      _mutate(slug, (project) => project.copyWith(notes: notes));

  /// Switches a project between a checklist and a document.
  ///
  /// Nothing is converted: the items and the body are both kept, so a project
  /// turned into notes and back is the file it was. Only which view opens
  /// changes, and a checklist keeps its front matter untouched.
  Future<void> setMode(String slug, ProjectMode mode) =>
      _mutate(slug, (project) => project.copyWith(mode: mode));

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

    final updated = change(
      current,
    ).copyWith(updated: DateTime.now().toUtc(), dirty: true);

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
    // The canvas layouts settle on their own timers too, and a canvas left
    // mid-drag when the app closes would otherwise keep one alive.
    for (final timer in _layoutTimers.values) {
      timer.cancel();
    }
    _layoutTimers.clear();
    super.dispose();
  }
}
