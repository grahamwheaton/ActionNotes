import 'dart:convert';

import 'package:actionnotes/markdown/project_markdown.dart';
import 'package:actionnotes/models/checklist_item.dart';
import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/state/search.dart';
import 'package:actionnotes/storage/github_client.dart';
import 'package:actionnotes/storage/sync_service.dart';
import 'package:actionnotes/ui/checklist_view.dart';
import 'package:actionnotes/ui/home_shell.dart';
import 'package:actionnotes/ui/note_editor.dart';
import 'package:actionnotes/ui/shortcuts_sheet.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

/// A repo that answers reads and records writes, so archiving and moving can
/// be checked by what they wrote and where.
class Recorder {
  final Map<String, String> files = {};
  final List<String> written = [];
  final List<List<int>> uploads = [];

  http.Client client() {
    return MockClient((request) async {
      final path = Uri.decodeFull(request.url.path).split('/contents/').last;

      if (request.method == 'PUT') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        written.add(path);
        final content = body['content'] as String;
        try {
          files[path] = utf8.decode(base64.decode(content));
        } on FormatException {
          uploads.add(base64.decode(content));
        }
        return stubResponse(jsonEncode({'content': {'sha': 'sha-1'}}), 200);
      }

      if (path.endsWith('/projects') || path.endsWith('/contents')) {
        return stubResponse('[]', 200);
      }
      final held = files[path];
      if (held == null) return stubResponse('Not Found', 404);
      return stubResponse(
        jsonEncode({
          'path': path,
          'sha': 'sha-held',
          'content': base64.encode(utf8.encode(held)),
        }),
        200,
      );
    });
  }
}

AppState stateFor(Recorder repo, FakeLocalStore store) => AppState(
      localStore: store,
      settingsStore: FakeSettingsStore(config: testConfig),
      syncService: SyncService(
        localStore: store,
        clientFactory: (config) => GitHubClient(config, client: repo.client()),
      ),
      attachmentStore: FakeAttachmentStore(),
      pushDelay: const Duration(milliseconds: 20),
    );

Future<void> pumpShell(WidgetTester tester, AppState state, {Size? size}) async {
  tester.view.physicalSize = size ?? const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(theme: AppTheme.light(), home: const HomeShell()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pumpAndSettle();
}

void main() {
  group('archiving completed items', () {
    test('writes them to the archive before taking them off the list',
        () async {
      final repo = Recorder();
      final store = FakeLocalStore();
      final state = stateFor(repo, store);
      await state.init();

      await state.createProject('List');
      await addItemsInOrder(state, 'list', ['Keep', 'Done thing']);
      await state.setItemNotes('list', 1, 'how it went');
      await state.toggleItem('list', 1);

      expect(await state.archiveCompleted('list'), isNull);

      // Out of the list, and into a file that is not scanned as a project.
      expect(state.projects.single.items.map((i) => i.text), ['Keep']);
      final archive = repo.files['archive/list.md']!;
      expect(archive, contains('- [x] Done thing'));
      expect(archive, contains('how it went'));
      expect(archive, contains('# List — archive'));
    });

    test('a second archive appends rather than replacing', () async {
      final repo = Recorder();
      final store = FakeLocalStore();
      final state = stateFor(repo, store);
      await state.init();

      await state.createProject('List');
      await state.addItem('list', 'First');
      await state.toggleItem('list', 0);
      await state.archiveCompleted('list');

      await state.addItem('list', 'Second');
      await state.toggleItem('list', 0);
      await state.archiveCompleted('list');

      final archive = repo.files['archive/list.md']!;
      expect(archive, contains('- [x] First'));
      expect(archive, contains('- [x] Second'));
    });

    test('an archived item reads back as the item it was', () async {
      final repo = Recorder();
      final store = FakeLocalStore();
      final state = stateFor(repo, store);
      await state.init();

      await state.createProject('List');
      await state.addItem('list', 'Starred and done');
      await state.toggleStar('list', 0);
      await state.toggleItem('list', 0);
      await state.archiveCompleted('list');

      // The lines are the format's own, so anything that reads a project file
      // can read the archive.
      final parsed = ProjectMarkdown.parse(
        repo.files['archive/list.md']!,
        slug: 'list',
      );
      expect(parsed.items.single.text, 'Starred and done');
      expect(parsed.items.single.starred, isTrue);
      expect(parsed.items.single.done, isTrue);
    });

    test('nothing completed archives nothing, and says so', () async {
      final repo = Recorder();
      final state = stateFor(repo, FakeLocalStore());
      await state.init();
      await state.createProject('List');
      await state.addItem('list', 'Open');

      expect(await state.archiveCompleted('list'), 'Nothing is completed yet.');
      expect(repo.files, isEmpty);
    });

    // The list is only tidied once the archive is written: a failure that
    // removed them anyway would be the deletion this replaced.
    test('a failed write leaves the list alone', () async {
      final store = FakeLocalStore();
      final state = AppState(
        localStore: store,
        settingsStore: FakeSettingsStore(config: testConfig),
        syncService: SyncService(
          localStore: store,
          clientFactory: (config) => GitHubClient(
            config,
            client: MockClient((request) async => request.method == 'PUT'
                ? stubResponse('{"message":"nope"}', 500)
                : stubResponse('Not Found', 404)),
          ),
        ),
        pushDelay: const Duration(milliseconds: 20),
      );
      await state.init();

      await state.createProject('List');
      await state.addItem('list', 'Done thing');
      await state.toggleItem('list', 0);

      expect(await state.archiveCompleted('list'), isNotNull);
      expect(state.projects.single.items, hasLength(1));
    });
  });

  group('moving an item', () {
    test('takes its notes with it', () async {
      final repo = Recorder();
      final state = stateFor(repo, FakeLocalStore());
      await state.init();

      await state.createProject('From');
      await state.createProject('To');
      await state.addItem('from', 'Wandering item');
      await state.setItemNotes('from', 0, 'why it matters');

      expect(await state.moveItem('from', 0, 'to'), isNull);

      expect(state.projectBySlug('from')!.items, isEmpty);
      final moved = state.projectBySlug('to')!.items.single;
      expect(moved.text, 'Wandering item');
      expect(moved.notes, 'why it matters');
    });

    // A note points at ../attachments/<slug>/, and the tidy-up after a push
    // deletes anything the project no longer mentions — so a move that left
    // the references alone would have the pictures deleted underneath it.
    test('copies the attachments and rewrites the references', () async {
      final repo = Recorder();
      final attachments = FakeAttachmentStore();
      final store = FakeLocalStore();
      final state = AppState(
        localStore: store,
        settingsStore: FakeSettingsStore(config: testConfig),
        syncService: SyncService(
          localStore: store,
          clientFactory: (config) => GitHubClient(config, client: repo.client()),
        ),
        attachmentStore: attachments,
        pushDelay: const Duration(milliseconds: 20),
      );
      await state.init();

      await state.createProject('From');
      await state.createProject('To');
      await state.addItem('from', 'With a picture');
      await state.setItemNotes(
        'from',
        0,
        '![shot.png](../attachments/from/shot.png)',
      );
      // The picture exists where the note says it does.
      await attachments.save('attachments/from/shot.png', [1, 2, 3]);

      expect(await state.moveItem('from', 0, 'to'), isNull);

      expect(
        state.projectBySlug('to')!.items.single.notes,
        contains('../attachments/to/shot.png'),
      );
      expect(repo.written, contains('attachments/to/shot.png'));
      expect(attachments.saved.containsKey('attachments/to/shot.png'), isTrue);
    });

    test('a picture that cannot be copied stops the move', () async {
      final repo = Recorder();
      final state = stateFor(repo, FakeLocalStore());
      await state.init();

      await state.createProject('From');
      await state.createProject('To');
      await state.addItem('from', 'With a missing picture');
      await state.setItemNotes(
        'from',
        0,
        '![gone.png](../attachments/from/gone.png)',
      );

      // Nothing cached and nothing on GitHub: the bytes cannot be had.
      final problem = await state.moveItem('from', 0, 'to');

      expect(problem, contains('gone.png'));
      expect(state.projectBySlug('from')!.items, hasLength(1));
      expect(state.projectBySlug('to')!.items, isEmpty);
    });

    test('moving into the same project does nothing', () async {
      final repo = Recorder();
      final state = stateFor(repo, FakeLocalStore());
      await state.init();
      await state.createProject('List');
      await state.addItem('list', 'Item');

      expect(await state.moveItem('list', 0, 'list'), isNull);
      expect(state.projects.single.items, hasLength(1));
    });
  });

  group('the tag index', () {
    test('counts every tag, most used first', () {
      final projects = [
        Project(slug: 'a', title: 'A', items: const [
          ChecklistItem(text: 'one [bug]'),
          ChecklistItem(text: 'two [bug] [ui]'),
        ]),
        Project(slug: 'b', title: 'B', items: const [
          ChecklistItem(text: 'three', notes: 'noted [bug]'),
        ]),
      ];

      final tags = ProjectSearch.tags(projects);

      expect(tags.map((t) => t.tag), ['bug', 'ui']);
      expect(tags.first.count, 3);
      expect(tags.last.count, 1);
    });

    testWidgets('an empty search box lists them, and picking one searches',
        (tester) async {
      final repo = Recorder();
      final state = stateFor(repo, FakeLocalStore());
      await state.init();
      await state.createProject('List');
      await state.addItem('list', 'Fix the sync [bug]');
      await pumpShell(tester, state);

      await tester.tap(find.byTooltip('Search').first);
      await tester.pumpAndSettle();

      // Browsing and searching in one place: the box is empty, so the tags
      // are what there is to see.
      expect(find.text('bug'), findsOneWidget);

      await tester.tap(find.text('bug'));
      await tester.pumpAndSettle();

      expect(find.text('Fix the sync'), findsWidgets);
      await settle(tester);
    });
  });

  group('a search hit', () {
    testWidgets('marks the item it found, not just its project',
        (tester) async {
      final repo = Recorder();
      final state = stateFor(repo, FakeLocalStore());
      await state.init();
      await state.createProject('List');
      await addItemsInOrder(state, 'list', ['First', 'Needle here', 'Third']);
      await pumpShell(tester, state);

      await tester.tap(find.byTooltip('Search').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Needle');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Needle here').first);
      await tester.pumpAndSettle();

      // The state handed the list an item to reveal, and the list took it.
      expect(state.revealed, isNull);
      expect(state.selectedSlug, 'list');
      expect(find.byType(ChecklistView), findsOneWidget);
      await settle(tester);
    });
  });

  group('the shortcuts sheet', () {
    testWidgets('opens from the sidebar', (tester) async {
      final repo = Recorder();
      final state = stateFor(repo, FakeLocalStore());
      await state.init();
      await pumpShell(tester, state);

      await tester.tap(find.byTooltip('Keyboard shortcuts'));
      await tester.pumpAndSettle();

      expect(find.text('Keyboard shortcuts'), findsWidgets);
      expect(find.text('Ctrl+Enter'), findsOneWidget);
    });

    testWidgets('opens on the keyboard', (tester) async {
      final repo = Recorder();
      final state = stateFor(repo, FakeLocalStore());
      await state.init();
      await pumpShell(tester, state);

      // Somewhere inside the shell has to hold focus, or a shortcut
      // registered inside it is not in the chain.
      await tester.tap(find.byType(TextField).first);
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pumpAndSettle();

      expect(find.text('Ctrl+K'), findsOneWidget);
    });

    test('every entry says what it does', () {
      for (final group in shortcutGroups) {
        expect(group.shortcuts, isNotEmpty, reason: group.where);
        for (final shortcut in group.shortcuts) {
          expect(shortcut.keys.trim(), isNotEmpty);
          expect(shortcut.description.trim(), isNotEmpty);
        }
      }
    });
  });

  group('the note editor on a phone', () {
    testWidgets('folds its buttons away so the title has the width',
        (tester) async {
      final repo = Recorder();
      final state = stateFor(repo, FakeLocalStore());
      await state.init();
      await state.createProject('List');
      await state.addItem(
        'list',
        'A task with a title long enough to need more than one line to read',
      );
      await pumpShell(tester, state, size: const Size(420, 900));

      await tester.tap(find.text('List'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('A task with a title'));
      await tester.pumpAndSettle();

      expect(find.byType(NoteEditor), findsOneWidget);
      // Undo, redo, link and image are in a menu; the star and Save are not.
      expect(find.byTooltip('Undo'), findsNothing);
      expect(find.byTooltip('More'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
      await settle(tester);
    });

    testWidgets('can star the item from inside the note', (tester) async {
      final repo = Recorder();
      final state = stateFor(repo, FakeLocalStore());
      await state.init();
      await state.createProject('List');
      await state.addItem('list', 'Write the report');
      await pumpShell(tester, state, size: const Size(420, 900));

      await tester.tap(find.text('List'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Write the report'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Star'));
      await tester.pumpAndSettle();

      expect(state.projects.single.items.single.starred, isTrue);
      // And it says so, rather than still offering to star it.
      expect(find.byTooltip('Remove star'), findsOneWidget);
      await settle(tester);
    });

    testWidgets('keeps its buttons where there is room', (tester) async {
      final repo = Recorder();
      final state = stateFor(repo, FakeLocalStore());
      await state.init();
      await state.createProject('List');
      await state.addItem('list', 'Write the report');
      await pumpShell(tester, state);

      await tester.tap(find.text('Write the report'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Undo'), findsOneWidget);
      expect(find.byTooltip('More'), findsNothing);
      await settle(tester);
    });
  });

  group('watching for changes', () {
    test('polls while the app is in front, and stops when it goes away',
        () async {
      final repo = Recorder();
      final store = FakeLocalStore();
      final state = AppState(
        localStore: store,
        settingsStore: FakeSettingsStore(config: testConfig),
        syncService: SyncService(
          localStore: store,
          clientFactory: (config) => GitHubClient(config, client: repo.client()),
        ),
        pushDelay: const Duration(milliseconds: 20),
        syncInterval: const Duration(milliseconds: 50),
      );
      await state.init();

      var syncs = 0;
      state.addListener(() {
        if (state.syncing) syncs++;
      });

      state.startWatching();
      await Future<void>.delayed(const Duration(milliseconds: 260));
      final while_ = syncs;
      expect(while_, greaterThan(1));

      state.stopWatching();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(syncs, while_);
    });
  });
}
