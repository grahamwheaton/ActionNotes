import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/storage/github_client.dart';
import 'package:actionnotes/storage/local_store.dart';
import 'package:actionnotes/storage/settings_store.dart';
import 'package:actionnotes/storage/sync_service.dart';

/// Keeps projects in memory so the UI can be driven without a filesystem.
class FakeLocalStore implements LocalStore {
  final Map<String, Project> saved = {};

  @override
  Future<List<Project>> loadAll() async => saved.values.toList();

  @override
  Future<void> save(Project project) async => saved[project.slug] = project;

  @override
  Future<void> delete(String slug) async => saved.remove(slug);
}

/// Reports no repo configured, so nothing tries to reach the network.
class FakeSettingsStore implements SettingsStore {
  @override
  Future<GitHubConfig> load() async =>
      const GitHubConfig(owner: '', repo: '', branch: 'main', token: '');

  @override
  Future<void> save(GitHubConfig config) async {}
}

AppState newTestState(FakeLocalStore store) => AppState(
      localStore: store,
      settingsStore: FakeSettingsStore(),
      syncService: SyncService(localStore: store),
    );
