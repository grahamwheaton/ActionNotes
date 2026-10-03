import 'dart:io';

import 'package:actionnotes/models/canvas_layout.dart';
import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/storage/local_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late LocalStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('actionnotes-persistence-');
    store = LocalStore(documentsDirectory: () async => root);
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'concurrent project and canvas saves preserve both metadata records',
    () async {
      final layout = CanvasLayout.empty
          .withSection('Board', const [CanvasSpot(x: 500, y: 20)])
          .copyWith(sha: 'canvas-sha', dirty: true);
      await Future.wait([
        store.save(Project(slug: 'list', title: 'List', notes: 'Old')),
        store.saveLayout('list', layout),
        store.save(
          Project(
            slug: 'list',
            title: 'List',
            notes: 'New',
            sha: 'project-sha',
            dirty: true,
          ),
        ),
      ]);
      final reopened = LocalStore(documentsDirectory: () async => root);
      final project = (await reopened.loadAll()).single;
      final canvas = await reopened.loadLayout('list');
      expect(project.notes, 'New');
      expect(project.sha, 'project-sha');
      expect(project.dirty, isTrue);
      expect(canvas.sha, 'canvas-sha');
      expect(canvas.dirty, isTrue);
      expect(canvas.spotsFor('Board').single.x, 500);
      expect(canvas.toJsonString(), isNot(contains('dirty')));
    },
  );

  test(
    'pending canvas deletion survives restart without a layout file',
    () async {
      await store.saveLayout(
        'list',
        CanvasLayout.empty.copyWith(sha: 'old-layout', dirty: true),
      );
      final reopened = LocalStore(documentsDirectory: () async => root);
      final pending = await reopened.loadLayout('list');
      expect(pending.isEmpty, isTrue);
      expect(pending.dirty, isTrue);
      expect(pending.sha, 'old-layout');
    },
  );

  test('a delayed remote layout cannot replace a queued local edit', () async {
    final local = CanvasLayout.empty
        .withSection('Board', const [CanvasSpot(x: 500, y: 20)])
        .copyWith(dirty: true);
    await Future.wait([
      store.saveLayout('list', local),
      store.saveLayout(
        'list',
        CanvasLayout.empty.withSection('Board', const [
          CanvasSpot(x: 10, y: 20),
        ]),
        preserveDirty: true,
      ),
    ]);
    final saved = await store.loadLayout('list');
    expect(saved.dirty, isTrue);
    expect(saved.spotsFor('Board').single.x, 500);
  });
}
