import 'package:actionnotes/markdown/feed_days.dart';
import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/ui/checklist_view.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_github.dart';
import 'support/fakes.dart';

const path = 'projects/daily-note.md';

String feed(String day, String entry) => '''
---
title: Daily note
mode: feed
---

# Daily note

## $day

$entry
''';

class FlakyLocalStore extends FakeLocalStore {
  bool failNextLoad = false;

  @override
  Future<List<Project>> loadAll({String sourceId = 'mine'}) {
    if (failNextLoad) {
      failNextLoad = false;
      throw StateError('simulated disk failure');
    }
    return super.loadAll(sourceId: sourceId);
  }
}

void main() {
  test('external SHA changes download clean Markdown into cache and AppState', () async {
    final github = FakeGitHub();
    final store = FakeLocalStore();
    final first = feed('2026-10-20', 'Old entry');
    github.repo(mine.repo)[path] = first;
    final state = stateWith(github, store);
    await state.init();
    await state.sync();

    final oldSha = store.saved['daily-note']!.sha;
    expect(oldSha, github.shaOf(mine.repo, path));
    expect(state.projectBySlug('daily-note')!.blocks.single.body, 'Old entry');
    final reads = github.reads.where((read) => read == path).length;

    await state.sync();
    expect(github.reads.where((read) => read == path).length, reads);

    github.repo(mine.repo)[path] = '$first\n## 2026-10-21\n\nNew entry\n';
    var notifications = 0;
    state.addListener(() => notifications++);
    await state.sync();

    final updated = state.projectBySlug('daily-note')!;
    expect(updated.sha, isNot(oldSha));
    expect(updated.blocks.last.body, 'New entry');
    expect(store.saved['daily-note']!.sha, updated.sha);
    expect(store.saved['daily-note']!.blocks.last.body, 'New entry');
    expect(github.reads.where((read) => read == path).length, reads + 1);
    expect(state.lastPulled, contains('Daily note'));
    expect(notifications, greaterThan(0));
    await settle(state);
  });

  test('a dirty local project is merged with external content, not replaced', () async {
    final github = FakeGitHub();
    final store = FakeLocalStore();
    github.repo(mine.repo)[path] = feed('2026-10-20', 'Remote old');
    final state = stateWith(github, store);
    await state.init();
    await state.sync();
    final local = store.saved['daily-note']!;
    store.saved['daily-note'] = local.copyWith(notes: 'Local unsent edit', dirty: true);
    github.repo(mine.repo)[path] = feed('2026-10-21', 'Remote new');

    await state.sync();

    final result = github.repo(mine.repo)[path]!;
    expect(result, contains('Local unsent edit'));
    expect(result, contains('Remote new'));
    await settle(state);
  });

  test('resume and manual Sync now both check externally changed files', () async {
    final github = FakeGitHub();
    final store = FakeLocalStore();
    github.repo(mine.repo)[path] = feed('2026-10-20', 'Initial');
    final state = stateWith(github, store);
    await state.init();
    await state.sync();
    state.startWatching();
    state.stopWatching();

    github.repo(mine.repo)[path] = feed('2026-10-21', 'On resume');
    await state.resumeWatching();
    expect(state.projectBySlug('daily-note')!.blocks.single.body, 'On resume');

    github.repo(mine.repo)[path] = feed('2026-10-22', 'On manual sync');
    await state.sync();
    expect(state.projectBySlug('daily-note')!.blocks.single.body, 'On manual sync');
    expect(state.syncError, isNull);
    state.stopWatching();
    await settle(state);
  });

  test('an unexpected failure reports status and does not poison later syncs', () async {
    final github = FakeGitHub();
    final store = FlakyLocalStore();
    github.repo(mine.repo)[path] = feed('2026-10-20', 'Initial');
    final state = stateWith(github, store);
    await state.init();
    await state.sync();

    store.failNextLoad = true;
    await state.sync();
    expect(state.syncing, isFalse);
    expect(state.syncError, contains('StateError'));

    github.repo(mine.repo)[path] = feed('2026-10-21', 'After failure');
    await state.sync();
    expect(state.syncError, isNull);
    expect(state.projectBySlug('daily-note')!.blocks.single.body, 'After failure');
    await settle(state);
  });

  testWidgets('feed view displays two successive external daily sections', (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final github = FakeGitHub();
    final store = FakeLocalStore();
    final today = FeedDays.titleFor(DateTime.now());
    github.repo(mine.repo)[path] = feed('2026-10-20', 'Old entry');
    final state = stateWith(github, store);
    await state.init();
    await state.sync();
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(theme: AppTheme.light(),
        home: const ChecklistView(slug: 'daily-note')),
    ));
    await tester.pumpAndSettle();

    github.repo(mine.repo)[path] =
        '${github.repo(mine.repo)[path]}\n## $today\n\nFirst external entry\n';
    await state.sync();
    await tester.pumpAndSettle();
    expect(find.textContaining('First external entry'), findsWidgets);

    github.repo(mine.repo)[path] =
        '${github.repo(mine.repo)[path]}\nSecond external entry\n';
    await state.sync();
    await tester.pumpAndSettle();
    expect(find.textContaining('Second external entry'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    await settle(state);
  });
}
