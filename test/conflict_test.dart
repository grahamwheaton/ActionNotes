import 'dart:convert';

import 'package:actionnotes/markdown/project_markdown.dart';
import 'package:actionnotes/markdown/project_merge.dart';
import 'package:actionnotes/models/checklist_item.dart';
import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/storage/github_client.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/storage/sync_service.dart';
import 'package:actionnotes/ui/home_shell.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

Project project({
  String slug = 'main-project',
  String title = 'Main Project',
  List<ChecklistItem> items = const [],
  String notes = '',
  String? sha,
  bool dirty = false,
}) {
  return Project(
    slug: slug,
    title: title,
    items: items,
    notes: notes,
    created: DateTime.utc(2026, 9, 1),
    updated: DateTime.utc(2026, 9, 16),
    sha: sha,
    dirty: dirty,
  );
}

void main() {
  group('merge', () {
    test('keeps items from both sides, local order first', () {
      final local = project(items: const [
        ChecklistItem(text: 'Quote brick undersides'),
        ChecklistItem(text: 'Reception'),
      ]);
      final remote = project(items: const [
        ChecklistItem(text: 'Reception'),
        ChecklistItem(text: 'Bedrooms'),
      ]);

      final merged = ProjectMerge.merge(local: local, remote: remote);

      expect(merged.items.map((i) => i.text),
          ['Quote brick undersides', 'Reception', 'Bedrooms']);
    });

    test('a completion on either side survives', () {
      final local = project(items: const [ChecklistItem(text: 'Reception')]);
      final remote = project(
        items: const [ChecklistItem(text: 'Reception', done: true)],
      );

      final merged = ProjectMerge.merge(local: local, remote: remote);

      expect(merged.items.single.done, isTrue);
    });

    test('a star on either side survives', () {
      final local = project(
        items: const [ChecklistItem(text: 'Doors', starred: true)],
      );
      final remote = project(items: const [ChecklistItem(text: 'Doors')]);

      final merged = ProjectMerge.merge(local: local, remote: remote);

      expect(merged.items.single.starred, isTrue);
    });

    test('items match regardless of case and surrounding space', () {
      final local = project(items: const [ChecklistItem(text: 'Reception')]);
      final remote =
          project(items: const [ChecklistItem(text: '  reception ', done: true)]);

      final merged = ProjectMerge.merge(local: local, remote: remote);

      expect(merged.items, hasLength(1));
      expect(merged.items.single.text, 'Reception');
      expect(merged.items.single.done, isTrue);
    });

    test('differing notes keep both halves', () {
      final local = project(
        items: const [ChecklistItem(text: 'Doors', notes: 'Rang Omar.')],
      );
      final remote = project(
        items: const [ChecklistItem(text: 'Doors', notes: 'Sizes confirmed.')],
      );

      final merged = ProjectMerge.merge(local: local, remote: remote);

      expect(merged.items.single.notes, contains('Rang Omar.'));
      expect(merged.items.single.notes, contains('Sizes confirmed.'));
    });

    test('identical notes are not duplicated', () {
      final local = project(
        items: const [ChecklistItem(text: 'Doors', notes: 'Same note.')],
      );
      final remote = project(
        items: const [ChecklistItem(text: 'Doors', notes: 'Same note.')],
      );

      final merged = ProjectMerge.merge(local: local, remote: remote);

      expect(merged.items.single.notes, 'Same note.');
    });

    test('front matter only GitHub knows about is kept', () {
      final local = project().copyWith(extraFrontMatter: {'mine': 'a'});
      final remote = project().copyWith(extraFrontMatter: {'theirs': 'b'});

      final merged = ProjectMerge.merge(local: local, remote: remote);

      expect(merged.extraFrontMatter, {'theirs': 'b', 'mine': 'a'});
    });
  });

  group('sync detects a conflict', () {
    test('a rejected push is reported with the live remote version', () async {
      final store = FakeLocalStore();
      final local = project(
        items: const [ChecklistItem(text: 'Mine')],
        sha: 'stale-sha',
        dirty: true,
      );
      store.saved[local.slug] = local;

      var putCalls = 0;
      final sync = SyncService(
        localStore: store,
        clientFactory: (config) => GitHubClient(
          config,
          client: stubClient(
            onPut: (_) {
              putCalls++;
              return stubResponse('{"message":"conflict"}', 409);
            },
            onGetFile: (_) => stubResponse(
              jsonEncode({
                'path': 'projects/main-project.md',
                'sha': 'fresh-sha',
                'content': base64.encode(utf8.encode(
                  ProjectMarkdown.serialize(
                    project(items: const [ChecklistItem(text: 'Theirs')]),
                  ),
                )),
              }),
              200,
            ),
            onList: () => stubResponse('[]', 200),
          ),
        ),
      );

      final result = await sync.sync(testConfig);

      expect(putCalls, 1);
      expect(result.ok, isFalse);
      expect(result.conflicts, hasLength(1));

      final conflict = result.conflicts.single;
      expect(conflict.local.items.single.text, 'Mine');
      expect(conflict.remote.items.single.text, 'Theirs');
      // The fresh SHA is what makes resolution able to write.
      expect(conflict.remote.sha, 'fresh-sha');
    });
  });

  group('resolving a conflict clears it', () {
    ProjectConflict buildConflict() => ProjectConflict(
          local: project(
            items: const [ChecklistItem(text: 'Mine')],
            sha: 'stale-sha',
            dirty: true,
          ),
          remote: project(
            items: const [ChecklistItem(text: 'Theirs')],
            sha: 'fresh-sha',
          ),
        );

    test('keeping GitHub needs no write and leaves nothing pending', () async {
      final store = FakeLocalStore();
      var putCalls = 0;
      final sync = SyncService(
        localStore: store,
        clientFactory: (config) => GitHubClient(
          config,
          client: stubClient(onPut: (_) {
            putCalls++;
            return stubResponse('{}', 200);
          }),
        ),
      );

      final settled = await sync.resolve(
        testConfig,
        buildConflict(),
        ConflictResolution.keepRemote,
      );

      expect(putCalls, 0);
      expect(settled.dirty, isFalse);
      expect(settled.items.single.text, 'Theirs');
      expect(store.saved['main-project']!.items.single.text, 'Theirs');
    });

    test('keeping mine pushes with the fresh SHA', () async {
      final store = FakeLocalStore();
      Map<String, dynamic>? body;
      final sync = SyncService(
        localStore: store,
        clientFactory: (config) => GitHubClient(
          config,
          client: stubClient(onPut: (request) {
            body = jsonDecode(request.body) as Map<String, dynamic>;
            return stubResponse(
              jsonEncode({
                'content': {'sha': 'settled-sha'},
              }),
              200,
            );
          }),
        ),
      );

      final settled = await sync.resolve(
        testConfig,
        buildConflict(),
        ConflictResolution.keepLocal,
      );

      // Writing with the stale SHA is what failed in the first place.
      expect(body!['sha'], 'fresh-sha');
      expect(settled.sha, 'settled-sha');
      expect(settled.dirty, isFalse);
      expect(settled.items.single.text, 'Mine');
    });

    test('merging pushes a version holding both items', () async {
      final store = FakeLocalStore();
      String? pushed;
      final sync = SyncService(
        localStore: store,
        clientFactory: (config) => GitHubClient(
          config,
          client: stubClient(onPut: (request) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            pushed = utf8.decode(base64.decode(body['content'] as String));
            return stubResponse(
              jsonEncode({
                'content': {'sha': 'settled-sha'},
              }),
              200,
            );
          }),
        ),
      );

      final settled = await sync.resolve(
        testConfig,
        buildConflict(),
        ConflictResolution.merge,
      );

      expect(settled.items.map((i) => i.text), ['Mine', 'Theirs']);
      expect(pushed, contains('- [ ] Mine'));
      expect(pushed, contains('- [ ] Theirs'));
      expect(settled.dirty, isFalse);
    });

    test('a failed resolving push keeps the fresh SHA so a retry can work',
        () async {
      final store = FakeLocalStore();
      final sync = SyncService(
        localStore: store,
        clientFactory: (config) => GitHubClient(
          config,
          client: stubClient(
            onPut: (_) => stubResponse('{"message":"boom"}', 500),
          ),
        ),
      );

      final settled = await sync.resolve(
        testConfig,
        buildConflict(),
        ConflictResolution.keepLocal,
      );

      expect(settled.dirty, isTrue);
      // Crucially not 'stale-sha', which is what made this unrecoverable.
      expect(settled.sha, 'fresh-sha');
    });
  });

  group('the app offers a way out', () {
    /// Builds a shell whose first sync hits a conflict.
    Future<AppState> pumpConflicted(
      WidgetTester tester,
      FakeLocalStore store,
    ) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      store.saved['main-project'] = project(
        items: const [ChecklistItem(text: 'Mine')],
        sha: 'stale-sha',
        dirty: true,
      );

      var resolved = false;
      final state = newTestState(
        store,
        config: testConfig,
        syncService: SyncService(
          localStore: store,
          clientFactory: (config) => GitHubClient(
            config,
            client: stubClient(
              onPut: (_) => resolved
                  ? stubResponse(
                      jsonEncode({
                        'content': {'sha': 'settled-sha'},
                      }),
                      200,
                    )
                  // The first push conflicts; once the app resolves with the
                  // fresh SHA, the write is accepted.
                  : (() {
                      resolved = true;
                      return stubResponse('{"message":"conflict"}', 409);
                    })(),
              onGetFile: (_) => stubResponse(
                jsonEncode({
                  'path': 'projects/main-project.md',
                  'sha': 'fresh-sha',
                  'content': base64.encode(utf8.encode(
                    ProjectMarkdown.serialize(
                      project(items: const [ChecklistItem(text: 'Theirs')]),
                    ),
                  )),
                }),
                200,
              ),
              onList: () => stubResponse('[]', 200),
            ),
          ),
        ),
      );

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state..init(),
          child: MaterialApp(theme: AppTheme.light(), home: const HomeShell()),
        ),
      );
      await tester.pumpAndSettle();
      return state;
    }

    testWidgets('a conflict shows a Resolve action, not a dead end',
        (tester) async {
      final store = FakeLocalStore();
      await pumpConflicted(tester, store);

      expect(find.textContaining('changed here and on GitHub'), findsOneWidget);
      expect(find.text('Resolve'), findsOneWidget);
    });

    testWidgets('resolving by merging clears the conflict', (tester) async {
      final store = FakeLocalStore();
      final state = await pumpConflicted(tester, store);

      expect(state.conflicts, hasLength(1));

      await tester.tap(find.text('Resolve'));
      await tester.pumpAndSettle();

      // Both versions and the merged preview are on offer.
      expect(find.text('On this device'), findsOneWidget);
      expect(find.text('On GitHub'), findsOneWidget);
      expect(find.text('Merge both'), findsOneWidget);

      await tester.tap(find.text('Merge both'));
      await tester.pumpAndSettle();

      expect(state.conflicts, isEmpty);
      expect(find.text('Resolve'), findsNothing);

      final saved = store.saved['main-project']!;
      expect(saved.items.map((i) => i.text), ['Mine', 'Theirs']);
      expect(saved.dirty, isFalse, reason: 'the project should sync again');
    });

    testWidgets('choosing GitHub discards the local edits', (tester) async {
      final store = FakeLocalStore();
      final state = await pumpConflicted(tester, store);

      await tester.tap(find.text('Resolve'));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Use GitHub's"));
      await tester.pumpAndSettle();

      expect(state.conflicts, isEmpty);
      expect(store.saved['main-project']!.items.single.text, 'Theirs');
    });
  });
}
