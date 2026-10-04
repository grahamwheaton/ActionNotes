import 'dart:io';

import 'package:actionnotes/markdown/project_markdown.dart';
import 'package:actionnotes/models/checklist_item.dart';
import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/storage/folder_store.dart';
import 'package:actionnotes/storage/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Project project({
  String slug = 'trip',
  String title = 'Trip',
  List<ChecklistItem> items = const [],
  String? sha,
  bool dirty = false,
}) => Project(
  slug: slug,
  title: title,
  items: items,
  created: DateTime.utc(2026, 10, 1),
  updated: DateTime.utc(2026, 10, 4),
  sha: sha,
  dirty: dirty,
);

void main() {
  late Directory root;
  late FakeLocalStore store;
  late SyncService sync;
  late FolderConfig config;

  File fileOf(String slug) => File('${root.path}/projects/$slug.md');

  setUp(() {
    root = Directory.systemTemp.createTempSync('actionnotes-folder-sync');
    Directory('${root.path}/projects').createSync();
    FolderStore.forgetAll();
    store = FakeLocalStore();
    sync = SyncService(localStore: store);
    config = FolderConfig(path: root.path, displayName: 'Work');
  });

  tearDown(() {
    FolderStore.forgetAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('a project made here is written into the folder as markdown', () async {
    store.saved['trip'] = project(
      items: const [ChecklistItem(text: 'Book the ferry')],
      dirty: true,
    );

    final result = await sync.sync(config);

    expect(result.ok, isTrue, reason: result.error);
    expect(result.pending, 0);
    expect(fileOf('trip').readAsStringSync(), contains('Book the ferry'));
    expect(store.saved['trip']!.dirty, isFalse);
    expect(store.saved['trip']!.sha, isNotNull);
  });

  test('a file that turns up in the folder becomes a project', () async {
    fileOf('groceries').writeAsStringSync(
      ProjectMarkdown.serialize(
        project(
          slug: 'groceries',
          title: 'Groceries',
          items: const [ChecklistItem(text: 'Milk')],
        ),
      ),
    );

    final result = await sync.sync(config);

    expect(result.ok, isTrue, reason: result.error);
    expect(result.projects.single.title, 'Groceries');
    expect(store.saved['groceries']!.items.single.text, 'Milk');
  });

  test('an edit made elsewhere comes through on the next sync', () async {
    fileOf('trip').writeAsStringSync(
      ProjectMarkdown.serialize(
        project(items: const [ChecklistItem(text: 'Old')]),
      ),
    );
    await sync.sync(config);

    // Another device, through the cloud app.
    fileOf('trip')
      ..writeAsStringSync(
        ProjectMarkdown.serialize(
          project(items: const [ChecklistItem(text: 'New')]),
        ),
      )
      ..setLastModifiedSync(DateTime.now().add(const Duration(minutes: 5)));

    await sync.sync(config);

    expect(store.saved['trip']!.items.single.text, 'New');
  });

  test('an edit here and an edit there are combined, not one lost', () async {
    // There already, from another device; never seen by this one.
    fileOf('trip').writeAsStringSync(
      ProjectMarkdown.serialize(
        project(items: const [ChecklistItem(text: 'Theirs')]),
      ),
    );
    store.saved['trip'] = project(
      items: const [ChecklistItem(text: 'Mine')],
      dirty: true,
    );

    final result = await sync.sync(config);

    expect(result.ok, isTrue, reason: result.error);
    expect(result.merged, ['Trip']);
    final text = fileOf('trip').readAsStringSync();
    expect(text, contains('Mine'));
    expect(text, contains('Theirs'));
    expect(store.saved['trip']!.dirty, isFalse);
  });

  test('a file deleted in the folder goes from here too', () async {
    fileOf('trip').writeAsStringSync(ProjectMarkdown.serialize(project()));
    await sync.sync(config);
    expect(store.saved, contains('trip'));

    fileOf('trip').deleteSync();
    await sync.sync(config);

    expect(store.saved, isEmpty);
  });

  test('a project with unsent edits survives its file being deleted', () async {
    fileOf('trip').writeAsStringSync(ProjectMarkdown.serialize(project()));
    await sync.sync(config);

    fileOf('trip').deleteSync();
    store.saved['trip'] = store.saved['trip']!.copyWith(
      items: const [ChecklistItem(text: 'Written after')],
      dirty: true,
    );
    await sync.sync(config);

    // It is put back, with the edit: local wins over a deletion.
    expect(fileOf('trip').readAsStringSync(), contains('Written after'));
  });

  test('a folder that has gone is reported and nothing is cleared', () async {
    fileOf('trip').writeAsStringSync(ProjectMarkdown.serialize(project()));
    await sync.sync(config);

    root.deleteSync(recursive: true);
    final result = await sync.sync(config);

    expect(result.ok, isFalse);
    expect(result.error, isNot(contains('GitHub')));
    expect(store.saved, contains('trip'));
  });

  test('a cloud drive that has not delivered the projects folder is not '
      'mistaken for everything being deleted', () async {
    fileOf('trip').writeAsStringSync(ProjectMarkdown.serialize(project()));
    await sync.sync(config);

    Directory('${root.path}/projects').deleteSync(recursive: true);
    final result = await sync.sync(config);

    expect(result.ok, isFalse);
    expect(store.saved, contains('trip'));
  });

  test('what was pushed can be listed back through the same store', () async {
    store.saved['trip'] = project(dirty: true);
    await sync.sync(config);

    final client = sync.clientFor(config);
    final listed = await client.listDirectory('projects');
    client.dispose();

    expect(listed.keys, ['projects/trip.md']);
  });
}
