import 'dart:async';

import 'package:flutter/foundation.dart';

import '../markdown/project_merge.dart';
import '../models/checklist_item.dart';
import '../models/project.dart';
import '../storage/attachment_store.dart';
import '../storage/github_client.dart';
import '../storage/local_store.dart';
import '../storage/settings_store.dart';
import '../storage/sync_service.dart';

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
  })  : _localStore = localStore ?? LocalStore(),
        _settingsStore = settingsStore ?? SettingsStore(),
        attachments = attachmentStore ?? AttachmentStore() {
    _syncService = syncService ?? SyncService(localStore: _localStore);
  }

  static const _pushDelay = Duration(seconds: 2);

  final LocalStore _localStore;
  final SettingsStore _settingsStore;

  /// Exposed so note rendering can resolve image references.
  final AttachmentStore attachments;
  late final SyncService _syncService;

  final Map<String, Timer> _pendingPushes = {};

  List<Project> _projects = [];
  GitHubConfig _config = const GitHubConfig(owner: '', repo: '', branch: 'main', token: '');
  bool _loading = true;
  bool _syncing = false;
  String? _message;
  String? _selectedSlug;
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
    notifyListeners();
  }

  Project? projectBySlug(String slug) {
    for (final project in _projects) {
      if (project.slug == slug) return project;
    }
    return null;
  }

  Future<void> init() async {
    _config = await _settingsStore.load();
    _projects = await _localStore.loadAll();
    _loading = false;
    notifyListeners();

    if (_config.isComplete) unawaited(sync());
  }

  Future<void> sync() async {
    if (_syncing) return;
    _syncing = true;
    notifyListeners();

    final result = await _syncService.sync(_config);
    _projects = result.projects;
    _message = result.error;
    _conflicts = result.conflicts;
    _syncing = false;
    notifyListeners();
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
        404 => 'No such repo, or the token cannot see it.',
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

  Future<void> addItem(String slug, String text) => _mutate(
        slug,
        (project) => project.copyWith(
          items: [...project.items, ChecklistItem(text: text.trim())],
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

    final name = AttachmentStore.uniqueFileName(fileName, taken);
    final repoPath = AttachmentStore.repoPath(slug, name);

    final client = GitHubClient(_config);
    try {
      await client.writeBytes(
        path: repoPath,
        bytes: bytes,
        message: 'Add attachment $name to ${project.title}',
      );
      // Cache it so the note renders without a round trip.
      await attachments.save(repoPath, bytes);
      return '![$name](${AttachmentStore.markdownPath(slug, name)})';
    } on GitHubException catch (error) {
      _message = 'Could not upload the image: ${error.message}';
      notifyListeners();
      return null;
    } catch (_) {
      _message = 'Could not reach GitHub to upload the image.';
      notifyListeners();
      return null;
    } finally {
      client.dispose();
    }
  }

  Future<void> removeItem(String slug, int index) => _mutate(slug, (project) {
        final items = [...project.items]..removeAt(index);
        return project.copyWith(items: items);
      });

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

  Future<void> clearCompleted(String slug) => _mutate(
        slug,
        (project) => project.copyWith(
          items: project.items.where((item) => !item.done).toList(),
        ),
      );

  Future<void> setNotes(String slug, String notes) =>
      _mutate(slug, (project) => project.copyWith(notes: notes));

  Future<void> deleteProject(String slug) async {
    final project = projectBySlug(slug);
    if (project == null) return;

    _pendingPushes.remove(slug)?.cancel();
    if (_selectedSlug == slug) _selectedSlug = null;
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
    _pendingPushes[slug] = Timer(_pushDelay, () async {
      _pendingPushes.remove(slug);
      final project = projectBySlug(slug);
      if (project == null || !project.dirty) return;

      final pushed = await _syncService.push(_config, project);
      if (pushed.dirty) return; // Still pending; the next sync will retry.

      final latest = projectBySlug(slug);
      if (latest == null) return;
      // Only clear the flag if nothing was edited while the push was in flight.
      if (latest.updated == project.updated) {
        final settled = latest.copyWith(sha: pushed.sha, dirty: false);
        _projects =
            _projects.map((p) => p.slug == slug ? settled : p).toList();
        await _localStore.save(settled);
        notifyListeners();
      }
    });
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
    for (final timer in _pendingPushes.values) {
      timer.cancel();
    }
    _pendingPushes.clear();
    super.dispose();
  }
}
