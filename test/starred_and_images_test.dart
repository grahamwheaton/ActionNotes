import 'dart:convert';
import 'dart:io';

import 'package:actionnotes/models/checklist_item.dart';
import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/storage/github_client.dart';
import 'package:actionnotes/storage/sync_service.dart';
import 'package:actionnotes/ui/checklist_view.dart';
import 'package:actionnotes/ui/home_shell.dart';
import 'package:actionnotes/ui/image_viewer.dart';
import 'package:actionnotes/ui/note_view.dart';
import 'package:actionnotes/ui/starred_screen.dart';
import 'package:actionnotes/ui/sync_status.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';

import 'support/fakes.dart';

Project project(String title, List<ChecklistItem> items) => Project(
      slug: title.toLowerCase(),
      title: title,
      items: items,
    );

AppState stateFor(FakeLocalStore store, {http.Client? client}) => AppState(
      localStore: store,
      settingsStore: FakeSettingsStore(config: testConfig),
      syncService: SyncService(
        localStore: store,
        clientFactory: (config) => GitHubClient(
          config,
          client: client ??
              MockClient((request) async => request.method == 'PUT'
                  ? stubResponse(jsonEncode({'content': {'sha': 'sha-1'}}), 200)
                  : stubResponse('[]', 200)),
        ),
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

Future<void> quiet(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pumpAndSettle();
}

void main() {
  group('everything starred', () {
    test('gathers the starred open items, in project order', () {
      final projects = [
        project('Work', const [
          ChecklistItem(text: 'plain'),
          ChecklistItem(text: 'starred one', starred: true),
          ChecklistItem(text: 'done and starred', starred: true, done: true),
        ]),
        project('Home', const [
          ChecklistItem(text: 'starred two', starred: true),
        ]),
      ];

      final starred = starredAcross(projects);

      // A starred item that is finished has had its moment.
      expect(starred.map((s) => s.item.text), ['starred one', 'starred two']);
      expect(starred.first.project.title, 'Work');
      // The index is into the project's own list, so opening it lands right.
      expect(starred.first.index, 1);
    });

    testWidgets('the sidebar counts them and opens the screen', (tester) async {
      final state = stateFor(FakeLocalStore());
      await state.init();
      await state.createProject('Work');
      await state.addItem('work', 'Urgent', starred: true);
      await state.createProject('Home');
      await state.addItem('home', 'Also urgent', starred: true);
      await pumpShell(tester, state);

      expect(find.byTooltip('Everything starred'), findsOneWidget);
      expect(find.text('2'), findsWidgets);

      await tester.tap(find.byTooltip('Everything starred'));
      await tester.pumpAndSettle();

      expect(find.byType(StarredScreen), findsOneWidget);
      expect(find.text('Urgent'), findsOneWidget);
      expect(find.text('Also urgent'), findsOneWidget);
      // Each says which project it came from, which is the point of one list.
      expect(find.text('Work'), findsWidgets);
      expect(find.text('Home'), findsWidgets);
      await quiet(tester);
    });

    testWidgets('picking one opens its project at that item', (tester) async {
      final state = stateFor(FakeLocalStore());
      await state.init();
      await state.createProject('Work');
      await addItemsInOrder(state, 'work', ['First', 'Starred one']);
      await state.toggleStar('work', 1);
      await state.createProject('Home');
      state.select('home');
      await pumpShell(tester, state);

      await tester.tap(find.byTooltip('Everything starred'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Starred one'));
      await tester.pumpAndSettle();

      expect(state.selectedSlug, 'work');
      expect(find.byType(StarredScreen), findsNothing);
      expect(find.byType(ChecklistView), findsOneWidget);
      // The list took the reveal, as it does for a search hit.
      expect(state.revealed, isNull);
      await quiet(tester);
    });

    testWidgets('says so when nothing is starred', (tester) async {
      final state = stateFor(FakeLocalStore());
      await state.init();
      await state.createProject('Work');
      await state.addItem('work', 'Ordinary');
      await pumpShell(tester, state);

      await tester.tap(find.byTooltip('Everything starred'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Nothing is starred'), findsOneWidget);
      await quiet(tester);
    });
  });

  group('the last sync', () {
    test('is recorded only when GitHub actually answered', () async {
      final store = FakeLocalStore();
      final state = stateFor(store);
      await state.init();
      // init starts a sync of its own when a repo is configured.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(state.lastSynced, isNotNull);

      // A sync that could not reach GitHub must not claim to have.
      final offline = AppState(
        localStore: store,
        settingsStore: FakeSettingsStore(config: testConfig),
        syncService: SyncService(
          localStore: store,
          clientFactory: (config) => GitHubClient(
            config,
            client: MockClient((_) async => throw const SocketException('down')),
          ),
        ),
      );
      await offline.init();
      await offline.sync();
      expect(offline.lastSynced, isNull);
    });

    test('reads as roundly as it can while staying true', () {
      final now = DateTime(2026, 9, 18, 12);
      String ago(Duration since) => syncAgo(now.subtract(since), now: now);

      expect(ago(const Duration(seconds: 5)), 'just now');
      expect(ago(const Duration(minutes: 1)), 'a minute ago');
      expect(ago(const Duration(minutes: 3)), '3 minutes ago');
      expect(ago(const Duration(hours: 1)), 'an hour ago');
      expect(ago(const Duration(hours: 5)), '5 hours ago');
      expect(ago(const Duration(days: 1)), 'yesterday');
      expect(ago(const Duration(days: 4)), '4 days ago');
    });

    testWidgets('the sidebar says when, and how much is waiting',
        (tester) async {
      final store = FakeLocalStore();
      // Nothing configured, so nothing has been heard from.
      final unsynced = AppState(
        localStore: store,
        settingsStore: FakeSettingsStore(),
        syncService: SyncService(localStore: store),
      );
      await unsynced.init();
      await pumpShell(tester, unsynced);
      expect(find.textContaining('Not connected'), findsOneWidget);

      final state = stateFor(store);
      await state.init();
      await pumpShell(tester, state);
      await state.sync();
      await tester.pumpAndSettle();
      expect(find.textContaining('Synced just now'), findsOneWidget);

      // An edit is pending until it is pushed, and says so alongside.
      await state.createProject('Work');
      await tester.pump();
      expect(find.textContaining('to push'), findsOneWidget);
      await quiet(tester);
    });
  });

  group('an image in a note', () {
    /// Writes a real PNG into the cache, so the renderer has one to draw.
    Future<AppState> withImage(WidgetTester tester) async {
      final attachments = FakeAttachmentStore();
      final store = FakeLocalStore();
      final state = AppState(
        localStore: store,
        settingsStore: FakeSettingsStore(config: testConfig),
        syncService: SyncService(localStore: store),
        attachmentStore: attachments,
        pushDelay: const Duration(milliseconds: 20),
      );
      await state.init();
      await attachments.save(
        'attachments/work/shot.png',
        img.encodePng(img.Image(width: 4, height: 4)),
      );

      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(
              body: NoteView(
                markdown: '![shot.png](../attachments/work/shot.png)',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Decoding a file happens off the framework's clock, so without real
      // time the picture is there but zero by zero and nothing can be
      // clicked.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      return state;
    }

    testWidgets('opens full size when clicked', (tester) async {
      await withImage(tester);

      expect(find.byType(Image), findsOneWidget);

      await tester.tap(find.byType(Image));
      await tester.pumpAndSettle();

      // A viewer that zooms, over the note.
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.byTooltip('Close'), findsOneWidget);
      expect(find.byTooltip('Copy'), findsOneWidget);
      expect(find.byTooltip('Save a copy'), findsOneWidget);
    });

    testWidgets('closes again', (tester) async {
      await withImage(tester);

      await tester.tap(find.byType(Image));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      expect(find.byType(InteractiveViewer), findsNothing);
    });

    testWidgets('right-click offers what else can be done with it',
        (tester) async {
      await withImage(tester);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(Image)),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.text('Open full size'), findsOneWidget);
      expect(find.text('Copy image'), findsOneWidget);
      expect(find.text('Save a copy...'), findsOneWidget);
      // Showing a file in its folder is a desktop idea; a phone has none.
      expect(
        find.text('Show in folder'),
        ImageActions.canReveal ? findsOneWidget : findsNothing,
      );
    });
  });
}

