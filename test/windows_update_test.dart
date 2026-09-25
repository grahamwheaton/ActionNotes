import 'dart:io';

import 'package:actionnotes/storage/windows_updater.dart';
import 'package:actionnotes/storage/sync_service.dart';
import 'package:actionnotes/storage/github_client.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:http/testing.dart';
import 'package:actionnotes/models/canvas_layout.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('actionnotes-stage-');
    File(
      '${root.path}/actionnotes_updater.exe',
    ).writeAsStringSync('old helper');
  });
  tearDown(() => root.deleteSync(recursive: true));

  File bundle({String? extra, String? omit}) {
    final archive = Archive();
    for (final name in [
      'actionnotes.exe',
      'actionnotes_updater.exe',
      'flutter_windows.dll',
      'data/app.so',
      'data/icudtl.dat',
      'data/flutter_assets/AssetManifest.bin',
      if (extra != null) extra,
    ]) {
      if (name != omit) archive.addFile(ArchiveFile.string(name, 'MZpayload'));
    }
    return File('${root.path}/release.zip')
      ..writeAsBytesSync(ZipEncoder().encode(archive));
  }

  test('stages the full bundle without changing the running app', () async {
    final original = File('${root.path}/actionnotes.exe')
      ..writeAsStringSync('original');
    final updater = WindowsUpdater(executable: original.path);
    final stage = await updater.stage(bundle());
    expect(original.readAsStringSync(), 'original');
    expect(
      File('${stage.path}/payload/data/app.so').readAsStringSync(),
      'MZpayload',
    );
    expect(File('${stage.path}/updater.exe').readAsStringSync(), 'old helper');
  });

  test('rejects unsafe archive paths and incomplete bundles', () async {
    final updater = WindowsUpdater(executable: '${root.path}/actionnotes.exe');
    for (final name in [
      '../escape.dll',
      'data/../../escape',
      'data/C:stream',
      'data/CON.txt',
      'data/file. ',
      'data/APP.so',
      '/absolute.dll',
      'my-notes.md',
    ]) {
      await expectLater(
        updater.stage(bundle(extra: name)),
        throwsFormatException,
      );
    }
    await expectLater(
      updater.stage(bundle(omit: 'flutter_windows.dll')),
      throwsFormatException,
    );
    expect(root.listSync().whereType<Directory>(), isEmpty);
  });

  test(
    'restart flushes editor buffers and canvas positions before timers fire',
    () async {
      final store = FakeLocalStore();
      final state = newTestState(store);
      await state.init();
      await state.createProject('List');
      await state.addBlock('list', 'Board');
      await state.setCanvas('list', 'Board', true);
      await state.setCanvasSpots('list', 'Board', const [
        CanvasSpot(x: 25, y: 70),
      ]);
      Future<void> saveEditor() => state.setNotes('list', 'last typed words');
      state.registerEditorSave(saveEditor);
      await state.prepareForUpdate();
      expect(store.saved['list']!.notes, 'last typed words');
      expect(store.layouts['list']!.spotsFor('Board').first.x, 25);
      state.unregisterEditorSave(saveEditor);
      state.dispose();
    },
  );

  test(
    'a pending canvas upload must succeed before an update can restart',
    () async {
      final store = FakeLocalStore();
      final sync = SyncService(
        localStore: store,
        clientFactory: (config) => GitHubClient(
          config,
          client: MockClient((_) async => stubResponse('offline', 503)),
        ),
      );
      final state = newTestState(store, config: testConfig, syncService: sync);
      await state.init();
      await state.sync();
      await state.createProject('List');
      await state.addBlock('list', 'Board');
      await state.setCanvas('list', 'Board', true);
      await state.setCanvasSpots('list', 'Board', const [
        CanvasSpot(x: 33, y: 44),
      ]);
      await expectLater(
        state.prepareForUpdate(),
        throwsA(isA<UpdatePreparationException>()),
      );
      expect(store.layouts['list']!.spotsFor('Board').first.x, 33);
      state.dispose();
    },
  );

  test('failed editor save prevents restart and can be retried', () async {
    final state = newTestState(FakeLocalStore());
    await state.init();
    Future<void> fail() async => throw const FileSystemException('disk full');
    state.registerEditorSave(fail);
    await expectLater(
      state.prepareForUpdate(),
      throwsA(isA<FileSystemException>()),
    );
    state.unregisterEditorSave(fail);
    await state.prepareForUpdate();
    state.dispose();
  });
}
