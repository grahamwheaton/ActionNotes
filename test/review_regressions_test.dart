import 'dart:async';

import 'package:actionnotes/markdown/project_markdown.dart';
import 'package:actionnotes/markdown/project_merge.dart';
import 'package:actionnotes/markdown/canvas_cards.dart';
import 'package:actionnotes/models/canvas_layout.dart';
import 'package:actionnotes/models/notes_source.dart';
import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/storage/github_client.dart';
import 'package:actionnotes/storage/sync_service.dart';
import 'package:actionnotes/ui/canvas_view.dart';
import 'package:actionnotes/ui/note_blocks_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'support/fake_github.dart';
import 'support/fakes.dart';

void main() {
  test(
    'offline canvas removal retries and a replacement starts without an old SHA',
    () async {
      final github = FakeGitHub();
      github.repo(mine.repo)['projects/list.md'] = '# List\n\n## Board\n';
      github.repo(mine.repo)['canvas/list.json'] = CanvasLayout.empty
          .withSection('Board', const [])
          .toJsonString();
      final store = FakeLocalStore();
      final state = stateWith(github, store);
      await state.init();
      await state.sync();
      github.closed.add(mine.repo);
      await state.setCanvas('list', 'Board', false);
      expect(store.layouts['list']!.dirty, isTrue);
      state.dispose();
      github.closed.clear();
      final restarted = stateWith(github, store);
      addTearDown(restarted.dispose);
      await restarted.init();
      await restarted.sync();
      expect(github.repo(mine.repo).containsKey('canvas/list.json'), isFalse);
      expect(restarted.layoutFor('list').sha, isNull);
      expect(restarted.layoutFor('list').dirty, isFalse);
      await restarted.setCanvas('list', 'Board', true);
      expect(github.repo(mine.repo).containsKey('canvas/list.json'), isTrue);
      expect(restarted.layoutFor('list').dirty, isFalse);
    },
  );

  test('review: duplicate task titles retain all remote notes in a merge', () {
    final local = ProjectMarkdown.parse(
      '# List\n\n- [ ] Local task\n',
      slug: 'list',
    );
    final remote = ProjectMarkdown.parse(
      '# List\n\n## Client A\n\n- [ ] Review\n  Important A\n\n'
      '## Client B\n\n- [ ] Review\n  Important B\n',
      slug: 'list',
    );
    final merged = ProjectMerge.merge(local: local, remote: remote);
    expect(ProjectMarkdown.serialize(merged), contains('Important A'));
    expect(merged.items, hasLength(3));
  });

  test('review: edit during sync survives the following sync', () async {
    final github = FakeGitHub();
    github.repo(mine.repo)['projects/list.md'] = '# List\n\nOriginal\n';
    final store = FakeLocalStore();
    Completer<void>? gate;
    Completer<void>? entered;
    final state = AppState(
      localStore: store,
      settingsStore: FakeSettingsStore(config: mine),
      pushDelay: const Duration(hours: 1),
      syncService: SyncService(
        localStore: store,
        clientFactory: (config) {
          final client = github.clientFor(config);
          return GitHubClient(
            config,
            client: MockClient((request) async {
              if (request.method == 'PUT' &&
                  request.url.path.endsWith('/projects/list.md') &&
                  gate != null) {
                entered!.complete();
                await gate.future;
              }
              final forwarded = http.Request(request.method, request.url)
                ..headers.addAll(request.headers)
                ..bodyBytes = request.bodyBytes;
              return http.Response.fromStream(await client.send(forwarded));
            }),
          );
        },
      ),
    );
    addTearDown(state.dispose);
    await state.init();
    await state.sync();
    await state.setNotes('list', 'Before sync');
    gate = Completer<void>();
    entered = Completer<void>();
    final syncing = state.sync();
    await entered.future.timeout(const Duration(seconds: 3));
    await state.setNotes('list', 'New work typed during sync');
    gate.complete();
    await syncing;
    gate = null;
    expect(state.projectBySlug('list')!.notes, 'New work typed during sync');
    expect(store.saved['list']!.notes, 'New work typed during sync');
    expect(store.saved['list']!.dirty, isTrue);
    // This second sync reads the persisted cache, exactly as the next poll does.
    await state.sync();
    expect(state.projectBySlug('list')!.notes, 'New work typed during sync');
  });

  test(
    'review: offline canvas position uploads after restart and reconnection',
    () async {
      final github = FakeGitHub();
      github.repo(mine.repo)['projects/list.md'] =
          '# List\n\n## Board\n\n  - Card\n';
      final old = CanvasLayout.empty.withSection('Board', const [
        CanvasSpot(x: 10, y: 20, width: 200, ref: 'Card'),
      ]);
      github.repo(mine.repo)['canvas/list.json'] = old.toJsonString();
      final store = FakeLocalStore();
      final state = stateWith(github, store);
      await state.init();
      await state.sync();
      github.closed.add(mine.repo);
      await state.setCanvasSpots('list', 'Board', const [
        CanvasSpot(x: 500, y: 20, width: 200, ref: 'Card'),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(store.layouts['list']!.toJsonString(), contains('500'));
      state.dispose();
      github.closed.clear();
      final restarted = stateWith(github, store);
      addTearDown(restarted.dispose);
      await restarted.init();
      await restarted.sync();
      expect(restarted.layoutFor('list').toJsonString(), contains('500'));
      expect(github.repo(mine.repo)['canvas/list.json'], contains('500'));
    },
  );

  testWidgets('review: canvas portal resolves inside its notebook', (
    tester,
  ) async {
    final store = FakeLocalStore();
    final settings = FakeSettingsStore();
    settings.shared.add(
      NotesSource(
        id: 'shared',
        kind: SourceKind.shared,
        config: settings.config,
      ),
    );
    await store.save(
      Project(
        slug: 'list',
        title: 'Personal list',
        notes: 'PERSONAL CONTENT',
        mode: ProjectMode.notes,
      ),
    );
    await store.save(
      Project(
        slug: 'shared~list',
        sourceId: 'shared',
        title: 'Shared list',
        notes: 'SHARED CONTENT',
        mode: ProjectMode.notes,
      ),
      sourceId: 'shared',
    );
    final state = AppState(
      localStore: store,
      settingsStore: settings,
      syncService: SyncService(localStore: store),
    );
    await state.init();
    addTearDown(state.dispose);
    final card = CanvasCards.text('[Shared list](list.md#project)');
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: CanvasView(
              slug: 'shared~board',
              section: 'Board',
              cards: [card],
              spots: [CanvasSpot(x: 0, y: 0, width: 300, ref: card.ref)],
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Shared list'), findsOneWidget);
    expect(find.text('Personal list'), findsNothing);
    // The unselected card intentionally intercepts pointers over its preview.
    await tester.tapAt(tester.getCenter(find.text('Shared list')));
    await tester.pump();
    final editor = tester.widget<NoteBlocksEditor>(
      find.byType(NoteBlocksEditor),
    );
    editor.onChanged('Edited shared notes');
    await tester.pump(const Duration(milliseconds: 650));
    expect(state.projectBySlug('shared~list')!.notes, 'Edited shared notes');
    expect(state.projectBySlug('list')!.notes, 'PERSONAL CONTENT');
  });
}
