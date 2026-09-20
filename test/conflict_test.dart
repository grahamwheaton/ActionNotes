import 'dart:convert';

import 'package:actionnotes/markdown/project_markdown.dart';
import 'package:actionnotes/markdown/project_merge.dart';
import 'package:actionnotes/models/checklist_item.dart';
import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/storage/github_client.dart';
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
      final local = project(
        items: const [
          ChecklistItem(text: 'Quote brick undersides'),
          ChecklistItem(text: 'Reception'),
        ],
      );
      final remote = project(
        items: const [
          ChecklistItem(text: 'Reception'),
          ChecklistItem(text: 'Bedrooms'),
        ],
      );

      final merged = ProjectMerge.merge(local: local, remote: remote);

      expect(merged.items.map((i) => i.text), [
        'Quote brick undersides',
        'Reception',
        'Bedrooms',
      ]);
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
      final remote = project(
        items: const [ChecklistItem(text: '  reception ', done: true)],
      );

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

  group('a push that loses the race is combined, not queried', () {
    /// A GitHub whose file has moved on: the first write is rejected, the
    /// second — carrying the fresh SHA — is accepted.
    SyncService overtakenOnce(FakeLocalStore store, {required List<int> puts}) {
      var rejected = false;
      return SyncService(
        localStore: store,
        clientFactory: (config) => GitHubClient(
          config,
          client: stubClient(
            onPut: (request) {
              puts.add(1);
              if (rejected) {
                return stubResponse(
                  jsonEncode({
                    'content': {'sha': 'settled-sha'},
                  }),
                  200,
                );
              }
              rejected = true;
              return stubResponse('{"message":"conflict"}', 409);
            },
            onGetFile: (_) => stubResponse(
              jsonEncode({
                'path': 'projects/main-project.md',
                'sha': 'fresh-sha',
                'content': base64.encode(
                  utf8.encode(
                    ProjectMarkdown.serialize(
                      project(items: const [ChecklistItem(text: 'Theirs')]),
                    ),
                  ),
                ),
              }),
              200,
            ),
            onList: () => stubResponse('[]', 200),
          ),
        ),
      );
    }

    test(
      'both sides end up in the file, and nothing is left pending',
      () async {
        final store = FakeLocalStore();
        store.saved['main-project'] = project(
          items: const [ChecklistItem(text: 'Mine')],
          sha: 'stale-sha',
          dirty: true,
        );

        final puts = <int>[];
        final result = await overtakenOnce(store, puts: puts).sync(testConfig);

        // Rejected once, then written again with what both people wrote.
        expect(puts, hasLength(2));
        expect(result.ok, isTrue);
        expect(result.pending, 0);

        final saved = store.saved['main-project']!;
        expect(saved.items.map((i) => i.text), ['Mine', 'Theirs']);
        expect(saved.dirty, isFalse, reason: 'it should sync again by itself');
        // Said out loud, because a list growing a line you did not write is
        // worth knowing about even though there is nothing to decide.
        expect(result.merged, ['Main Project']);
      },
    );

    test(
      'a push rejected for any other reason is reported, not combined',
      () async {
        final store = FakeLocalStore();
        store.saved['main-project'] = project(
          items: const [ChecklistItem(text: 'Mine')],
          sha: 'stale-sha',
          dirty: true,
        );

        final sync = SyncService(
          localStore: store,
          clientFactory: (config) => GitHubClient(
            config,
            client: stubClient(
              onPut: (_) => stubResponse('{"message":"server on fire"}', 500),
              onList: () => stubResponse('[]', 200),
            ),
          ),
        );

        final result = await sync.sync(testConfig);

        expect(result.ok, isFalse);
        expect(result.error, contains('server on fire'));
        expect(result.merged, isEmpty);
        // Still dirty, so it goes out when GitHub is well again.
        expect(store.saved['main-project']!.dirty, isTrue);
      },
    );
  });

  group('the app never asks about it', () {
    testWidgets('it combines both sides and says so, with nothing to press', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final store = FakeLocalStore();
      store.saved['main-project'] = project(
        items: const [ChecklistItem(text: 'Mine')],
        sha: 'stale-sha',
        dirty: true,
      );

      var rejected = false;
      final state = newTestState(
        store,
        config: testConfig,
        syncService: SyncService(
          localStore: store,
          clientFactory: (config) => GitHubClient(
            config,
            client: stubClient(
              onPut: (_) {
                if (rejected) {
                  return stubResponse(
                    jsonEncode({
                      'content': {'sha': 'settled-sha'},
                    }),
                    200,
                  );
                }
                rejected = true;
                return stubResponse('{"message":"conflict"}', 409);
              },
              onGetFile: (_) => stubResponse(
                jsonEncode({
                  'path': 'projects/main-project.md',
                  'sha': 'fresh-sha',
                  'content': base64.encode(
                    utf8.encode(
                      ProjectMarkdown.serialize(
                        project(items: const [ChecklistItem(text: 'Theirs')]),
                      ),
                    ),
                  ),
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

      // Nothing to resolve, because nothing was left undecided.
      expect(find.text('Resolve'), findsNothing);
      expect(
        find.textContaining('Both sets of changes are in'),
        findsOneWidget,
      );

      final saved = store.saved['main-project']!;
      expect(saved.items.map((i) => i.text), ['Mine', 'Theirs']);
      expect(saved.dirty, isFalse);
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
