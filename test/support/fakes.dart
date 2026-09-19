import 'package:flutter/material.dart';

import 'dart:io';

import 'package:actionnotes/models/canvas_layout.dart';
import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/storage/attachment_store.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/storage/github_client.dart';
import 'package:actionnotes/storage/local_store.dart';
import 'package:actionnotes/storage/settings_store.dart';
import 'package:actionnotes/storage/sync_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Keeps projects in memory so the UI can be driven without a filesystem.
class FakeLocalStore implements LocalStore {
  /// Canvas layouts, kept in memory the way the projects are.
  final Map<String, CanvasLayout> layouts = {};

  @override
  Future<CanvasLayout> loadLayout(String slug) async =>
      layouts[slug] ?? CanvasLayout.empty;

  @override
  Future<void> saveLayout(String slug, CanvasLayout layout) async {
    if (layout.isEmpty) {
      layouts.remove(slug);
    } else {
      layouts[slug] = layout;
    }
  }

  final Map<String, Project> saved = {};

  @override
  Future<List<Project>> loadAll() async => saved.values.toList();

  @override
  Future<void> save(Project project) async => saved[project.slug] = project;

  @override
  Future<void> delete(String slug) async => saved.remove(slug);
}

/// Keeps attachments in memory, in a temporary directory: the real store
/// writes to the documents directory, which a test has no plugin for.
class FakeAttachmentStore extends AttachmentStore {
  final Map<String, List<int>> saved = {};

  Directory? _dir;

  Directory get _root =>
      _dir ??= Directory.systemTemp.createTempSync('actionnotes-test');

  File _fileFor(String repoPath) =>
      File('${_root.path}/${repoPath.replaceAll('/', '_')}');

  @override
  Future<File> save(String repoPath, List<int> bytes) async {
    saved[repoPath] = bytes;
    return _fileFor(repoPath)..writeAsBytesSync(bytes);
  }

  @override
  Future<File?> cached(String repoPath) async {
    final file = _fileFor(repoPath);
    return file.existsSync() ? file : null;
  }

  @override
  Future<File?> resolve(String repoPath, GitHubConfig config) =>
      cached(repoPath);
}

/// Reports no repo configured by default, so nothing tries to reach the
/// network unless a test opts in with a complete config.
class FakeSettingsStore implements SettingsStore {
  FakeSettingsStore({
    this.config = const GitHubConfig(
      owner: '',
      repo: '',
      branch: 'main',
      token: '',
    ),
  });

  final GitHubConfig config;

  /// What a test's app was last told to remember.
  ThemeMode themeMode = ThemeMode.system;

  @override
  Future<GitHubConfig> load() async => config;

  @override
  Future<void> save(GitHubConfig config) async {}

  String? login;

  @override
  Future<String?> loadLogin() async => login;

  @override
  Future<void> saveLogin(String? value) async => login = value;

  @override
  Future<ThemeMode> loadThemeMode() async => themeMode;

  @override
  Future<void> saveThemeMode(ThemeMode mode) async => themeMode = mode;
}

/// Adds items so the project reads in this order, top first.
///
/// addItem puts new items at the top, so they go in bottom-up.
Future<void> addItemsInOrder(
  AppState state,
  String slug,
  List<String> texts,
) async {
  for (final text in texts.reversed) {
    await state.addItem(slug, text);
  }
}

AppState newTestState(
  FakeLocalStore store, {
  GitHubConfig? config,
  SyncService? syncService,
  FakeAttachmentStore? attachments,
}) {
  return AppState(
    localStore: store,
    settingsStore: config == null
        ? FakeSettingsStore()
        : FakeSettingsStore(config: config),
    syncService: syncService ?? SyncService(localStore: store),
    attachmentStore: attachments,
  );
}

/// A repo config that looks complete, so code paths gated on it are exercised.
const testConfig = GitHubConfig(
  owner: 'graham',
  repo: 'notes',
  branch: 'main',
  token: 'tok',
);

http.Response stubResponse(String body, int status) =>
    http.Response(body, status, headers: {'content-type': 'application/json'});

/// Routes the few request shapes the sync code makes, so a test only has to
/// describe the ones it cares about.
http.Client stubClient({
  http.Response Function(http.Request request)? onPut,
  http.Response Function(String path)? onGetFile,
  http.Response Function()? onList,
}) {
  return MockClient((request) async {
    if (request.method == 'PUT') {
      return onPut?.call(request) ?? stubResponse('{}', 500);
    }
    final path = request.url.path;
    if (path.endsWith('/projects')) {
      return onList?.call() ?? stubResponse('[]', 200);
    }
    return onGetFile?.call(path) ?? stubResponse('Not Found', 404);
  });
}
