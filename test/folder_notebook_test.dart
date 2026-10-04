import 'dart:io';

import 'package:actionnotes/markdown/project_markdown.dart';
import 'package:actionnotes/models/notes_source.dart';
import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/storage/folder_backend.dart';
import 'package:actionnotes/storage/folder_store.dart';
import 'package:actionnotes/storage/github_client.dart';
import 'package:actionnotes/storage/notebook_index.dart';
import 'package:actionnotes/storage/settings_store.dart';
import 'package:actionnotes/storage/share_code.dart';
import 'package:actionnotes/storage/sync_service.dart';
import 'package:actionnotes/storage/vault.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_github.dart';
import 'support/fakes.dart';

/// Waits, on the real clock, for something the app does on a timer.
Future<void> eventually(bool Function() done) async {
  for (var i = 0; i < 150 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late FakeLocalStore store;
  late FakeSettingsStore settings;

  setUp(() {
    root = Directory.systemTemp.createTempSync('actionnotes-folder-notebook');
    FolderStore.forgetAll();
    store = FakeLocalStore();
    settings = FakeSettingsStore();
  });

  tearDown(() {
    FolderStore.forgetAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  AppState newState() => AppState(
    localStore: store,
    settingsStore: settings,
    syncService: SyncService(localStore: store),
    pushDelay: const Duration(milliseconds: 10),
  );

  group('adding a folder', () {
    test('an empty folder is set up, and listed beside your own', () async {
      final state = newState();
      await state.init();

      final problem = await state.addFolderNotebook(
        root.path,
        folderName: 'Work',
      );

      expect(problem, isNull);
      expect(state.sources, hasLength(2));
      expect(state.folderSources.single.name, 'Work');
      expect(state.folderSources.single.isFolder, isTrue);
      expect(Directory('${root.path}/projects').existsSync(), isTrue);
      expect(
        File('${root.path}/.actionnotes/vault.json').existsSync(),
        isTrue,
      );
      await settle(state);
    });

    test('a folder that is already a notebook is connected to', () async {
      final info = await Vault(
        IoFolderBackend(root.path),
      ).open(name: 'Family');
      File('${root.path}/projects/shopping.md').writeAsStringSync(
        ProjectMarkdown.serialize(
          Project(slug: 'shopping', title: 'Shopping'),
        ),
      );

      final state = newState();
      await state.init();
      final problem = await state.addFolderNotebook(
        root.path,
        folderName: 'Notes',
      );

      expect(problem, isNull);
      final source = state.folderSources.single;
      expect(source.id, NotesSource.idForVault(info.id));
      // The name the notebook was set up with, not this device's folder name.
      expect(source.name, 'Family');
      expect(
        state.projects.where((p) => p.sourceId == source.id).single.title,
        'Shopping',
      );
      await settle(state);
    });

    test('a name given here is used instead', () async {
      final state = newState();
      await state.init();

      await state.addFolderNotebook(
        root.path,
        folderName: 'Work',
        label: 'Office',
      );

      expect(state.folderSources.single.name, 'Office');
      await settle(state);
    });

    test('the same folder twice adds it once', () async {
      final state = newState();
      await state.init();
      await state.addFolderNotebook(root.path, folderName: 'Work');

      final again = await state.addFolderNotebook(
        root.path,
        folderName: 'Work',
      );

      expect(again, 'You already have that notebook.');
      expect(state.folderSources, hasLength(1));
      await settle(state);
    });

    test('a folder that is not there says so and is not kept', () async {
      final state = newState();
      await state.init();
      final missing = '${root.path}/nope';

      final problem = await state.addFolderNotebook(missing);

      expect(problem, isNotNull);
      expect(state.folderSources, isEmpty);
      await settle(state);
    });

    test('nothing chosen is asked for', () async {
      final state = newState();
      await state.init();

      expect(await state.addFolderNotebook(''), 'Pick a folder first.');
      await settle(state);
    });

    test('the choice is remembered', () async {
      final state = newState();
      await state.init();
      await state.addFolderNotebook(root.path, folderName: 'Work');

      expect(settings.shared.single.isFolder, isTrue);
      await settle(state);
    });
  });

  group('using one', () {
    test('a project made in it is written to the folder', () async {
      final state = newState();
      await state.init();
      await state.addFolderNotebook(root.path, folderName: 'Work');
      final id = state.folderSources.single.id;

      final project = await state.createProject('Roadmap');
      await state.moveProject(project.slug, id);
      final written = File('${root.path}/projects/roadmap.md');
      await eventually(written.existsSync);

      expect(written.existsSync(), isTrue);
      await settle(state);
    });

    test('it has no share code, and is not offered to other devices', () async {
      final state = newState();
      await state.init();
      await state.addFolderNotebook(root.path, folderName: 'Work');
      final source = state.folderSources.single;

      expect(state.shareCodeFor(source.id), isNull);
      expect(NotebookIndex.of(state.sources).isEmpty, isTrue);
      await settle(state);
    });

    test('letting go of it leaves the folder as it was', () async {
      final state = newState();
      await state.init();
      await state.addFolderNotebook(root.path, folderName: 'Work');
      File('${root.path}/projects/keep.md').writeAsStringSync(
        ProjectMarkdown.serialize(Project(slug: 'keep', title: 'Keep')),
      );
      await state.sync();
      final id = state.folderSources.single.id;

      await state.forgetSharedNotebook(id);

      expect(state.folderSources, isEmpty);
      expect(state.projects, isEmpty);
      expect(File('${root.path}/projects/keep.md').existsSync(), isTrue);
      expect(settings.shared, isEmpty);
      await settle(state);
    });

    test('a notebook shared by code still gets one, beside a folder', () async {
      final github = FakeGitHub();
      final state = AppState(
        localStore: store,
        settingsStore: FakeSettingsStore(config: mine),
        syncService: SyncService(
          localStore: store,
          // A repo goes to the fake GitHub, a folder to the real disk.
          clientFactory: (config) => config is FolderConfig
              ? FolderStore(config)
              : GitHubClient(config, client: github.clientFor(config)),
        ),
        pushDelay: const Duration(milliseconds: 10),
      );
      await state.init();
      await state.addSharedNotebook(ShareCode.encode(theirs));
      await state.addFolderNotebook(root.path, folderName: 'Work');

      expect(state.codeSources, hasLength(1));
      expect(state.folderSources, hasLength(1));
      expect(state.sharedSources, hasLength(2));
      expect(NotebookIndex.of(state.sources).entries, hasLength(1));
      await settle(state);
    });
  });

  group('how a folder notebook is stored on this device', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('it survives a restart without needing a token', () async {
      final real = SettingsStore();
      final source = NotesSource.inFolder(
        const FolderConfig(path: '/home/me/OneDrive/Work', displayName: 'Work'),
        vaultId: 'abc123def456',
        label: 'Office',
      );

      await real.saveSharedSources([source]);
      final loaded = await real.loadSources();

      expect(loaded, hasLength(2));
      expect(loaded.last, source);
      expect(loaded.last.isFolder, isTrue);
      expect(loaded.last.config.isComplete, isTrue);
    });

    test('an Android folder keeps its address and its name', () async {
      final real = SettingsStore();
      final source = NotesSource.inFolder(
        const FolderConfig(
          path: 'content://com.android.externalstorage.documents/tree/x',
          displayName: 'Family',
        ),
        vaultId: 'abc123def456',
      );

      await real.saveSharedSources([source]);
      final loaded = (await real.loadSources()).last;

      expect(
        (loaded.config as FolderConfig).path,
        'content://com.android.externalstorage.documents/tree/x',
      );
      expect(loaded.name, 'Family');
      expect(loaded.where, 'Folder Family');
    });

    test('an entry with no folder is ignored rather than trusted', () {
      expect(
        NotesSource.fromJson({'id': 'folder-x', 'kind': 'folder'}, ''),
        isNull,
      );
      expect(
        NotesSource.fromJson({
          'id': 'folder-x',
          'kind': 'folder',
          'path': '',
        }, ''),
        isNull,
      );
    });
  });
}
