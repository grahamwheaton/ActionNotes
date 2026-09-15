import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/checklist_item.dart';
import '../models/project.dart';
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
  })  : _localStore = localStore ?? LocalStore(),
        _settingsStore = settingsStore ?? SettingsStore() {
    _syncService = syncService ?? SyncService(localStore: _localStore);
  }

  static const _pushDelay = Duration(seconds: 2);

  final LocalStore _localStore;
  final SettingsStore _settingsStore;
  late final SyncService _syncService;

  final Map<String, Timer> _pendingPushes = {};

  List<Project> _projects = [];
  GitHubConfig _config = const GitHubConfig(owner: '', repo: '', branch: 'main', token: '');
  bool _loading = true;
  bool _syncing = false;
  String? _message;

  List<Project> get projects => List.unmodifiable(_projects);
  GitHubConfig get config => _config;
  bool get loading => _loading;
  bool get syncing => _syncing;
  String? get message => _message;
  bool get isConfigured => _config.isComplete;
  int get pendingCount => _projects.where((p) => p.dirty).length;

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
    _syncing = false;
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

  Future<void> removeItem(String slug, int index) => _mutate(slug, (project) {
        final items = [...project.items]..removeAt(index);
        return project.copyWith(items: items);
      });

  /// Moves an item to [newIndex], which is the index it should end up at once
  /// the item has been lifted out — what ReorderableListView's onReorderItem
  /// already gives us, so no off-by-one adjustment is needed here.
  Future<void> reorderItems(String slug, int oldIndex, int newIndex) =>
      _mutate(slug, (project) {
        final items = [...project.items];
        items.insert(newIndex, items.removeAt(oldIndex));
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
