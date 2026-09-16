import 'package:actionnotes/models/checklist_item.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/storage/attachment_store.dart';
import 'package:actionnotes/ui/home_shell.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

Future<AppState> pumpShell(
  WidgetTester tester,
  FakeLocalStore store, {
  Size size = const Size(1280, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final state = newTestState(store);
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state..init(),
      child: MaterialApp(theme: AppTheme.light(), home: const HomeShell()),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

void main() {
  group('completed grouping', () {
    testWidgets('completed items collapse under a header at the bottom',
        (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);

      await state.createProject('MY TODO');
      for (final text in ['Quote brick undersides', 'Reception', 'Bedrooms']) {
        await state.addItem('my-todo', text);
      }
      await state.toggleItem('my-todo', 1);
      await state.toggleItem('my-todo', 2);
      await tester.pumpAndSettle();

      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('2'), findsWidgets);

      // The open item sits above the Completed header, the done ones below.
      final openY = tester.getTopLeft(find.text('Quote brick undersides')).dy;
      final headerY = tester.getTopLeft(find.text('Completed')).dy;
      final doneY = tester.getTopLeft(find.text('Reception')).dy;
      expect(openY, lessThan(headerY));
      expect(headerY, lessThan(doneY));
    });

    testWidgets('tapping the header hides the completed items', (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);

      await state.createProject('List');
      await state.addItem('list', 'Done thing');
      await state.toggleItem('list', 0);
      await tester.pumpAndSettle();

      expect(find.text('Done thing'), findsOneWidget);

      await tester.tap(find.text('Completed'));
      await tester.pumpAndSettle();

      expect(find.text('Done thing'), findsNothing);
    });

    testWidgets('no header appears when nothing is completed', (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);

      await state.createProject('List');
      await state.addItem('list', 'Open thing');
      await tester.pumpAndSettle();

      expect(find.text('Completed'), findsNothing);
    });

    testWidgets('grouping addresses the right item when toggling',
        (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);

      await state.createProject('List');
      for (final text in ['First', 'Second', 'Third']) {
        await state.addItem('list', text);
      }
      // Complete the middle one, so the view order no longer matches the file.
      await state.toggleItem('list', 1);
      await tester.pumpAndSettle();

      // Re-opening it from the completed group must target 'Second'.
      final secondCheckbox = find.ancestor(
        of: find.text('Second'),
        matching: find.byType(Row),
      );
      await tester.tap(
        find.descendant(of: secondCheckbox.first, matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();

      final items = store.saved['list']!.items;
      expect(items.map((i) => i.text), ['First', 'Second', 'Third']);
      expect(items.every((i) => !i.done), isTrue);
    });
  });

  group('reordering', () {
    testWidgets('open items show a drag handle, completed ones do not',
        (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);

      await state.createProject('List');
      await state.addItem('list', 'Open');
      await state.addItem('list', 'Done');
      await state.toggleItem('list', 1);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.drag_indicator), findsOneWidget);
    });

    test('reordering open items leaves completed ones in place', () async {
      final store = FakeLocalStore();
      final state = newTestState(store);
      await state.init();

      await state.createProject('List');
      for (final text in ['A', 'B', 'C', 'D']) {
        await state.addItem('list', text);
      }
      // B and D complete, so open items are A (slot 0) and C (slot 2).
      await state.toggleItem('list', 1);
      await state.toggleItem('list', 3);

      // Move C before A.
      await state.reorderOpenItems('list', 1, 0);

      final items = store.saved['list']!.items;
      expect(items.map((i) => i.text), ['C', 'B', 'A', 'D']);
      expect(items.map((i) => i.done), [false, true, false, true]);
    });

    test('reordering with nothing completed behaves as a plain move', () async {
      final store = FakeLocalStore();
      final state = newTestState(store);
      await state.init();

      await state.createProject('List');
      for (final text in ['A', 'B', 'C']) {
        await state.addItem('list', text);
      }

      await state.reorderOpenItems('list', 0, 2);

      expect(store.saved['list']!.items.map((i) => i.text), ['B', 'C', 'A']);
    });
  });

  group('stars', () {
    testWidgets('the star button toggles and persists the flag',
        (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);

      await state.createProject('List');
      await state.addItem('list', 'Important thing');
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.star_border), findsOneWidget);

      await tester.tap(find.byIcon(Icons.star_border));
      await tester.pumpAndSettle();

      expect(store.saved['list']!.items.single.starred, isTrue);
      expect(find.byIcon(Icons.star), findsOneWidget);

      await tester.tap(find.byIcon(Icons.star));
      await tester.pumpAndSettle();

      expect(store.saved['list']!.items.single.starred, isFalse);
    });
  });

  group('context menu', () {
    testWidgets('right-clicking an item offers delete, and it works',
        (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);

      await state.createProject('List');
      await state.addItem('list', 'Doomed item');
      await state.addItem('list', 'Surviving item');
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Doomed item')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.text('Delete'), findsOneWidget);
      expect(find.text('Star'), findsOneWidget);
      expect(find.text('Add notes'), findsOneWidget);

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(store.saved['list']!.items.map((i) => i.text),
          ['Surviving item']);
    });

    testWidgets('long-press opens the same menu for touch', (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);

      await state.createProject('List');
      await state.addItem('list', 'An item');
      await tester.pumpAndSettle();

      await tester.longPress(find.text('An item'));
      await tester.pumpAndSettle();

      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('right-clicking a project offers rename and delete',
        (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);

      await state.createProject('A project');
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('A project').first),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });
  });

  group('sidebar', () {
    testWidgets('a wide window shows the project sidebar', (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);

      await state.createProject('Alpha');
      await state.createProject('Beta');
      await tester.pumpAndSettle();

      expect(find.byType(ProjectSidebar), findsOneWidget);
      expect(find.text('ActionNotes'), findsOneWidget);
      // Both names listed, and one of them open in the detail pane.
      expect(find.text('Alpha'), findsWidgets);
      expect(find.text('Beta'), findsOneWidget);
    });

    testWidgets('selecting a project swaps the detail pane', (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);

      await state.createProject('Alpha');
      await state.addItem('alpha', 'Alpha item');
      await state.createProject('Beta');
      await state.addItem('beta', 'Beta item');
      await tester.pumpAndSettle();

      state.select('beta');
      await tester.pumpAndSettle();

      expect(find.text('Beta item'), findsOneWidget);
      expect(find.text('Alpha item'), findsNothing);
    });

    testWidgets('a narrow window shows no sidebar chrome', (tester) async {
      final store = FakeLocalStore();
      await pumpShell(tester, store, size: const Size(420, 900));

      expect(find.text('Projects'), findsOneWidget);
      expect(find.text('ActionNotes'), findsNothing);
    });
  });

  group('item notes', () {
    testWidgets('an item with notes shows a marker', (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);

      await state.createProject('List');
      await state.addItem('list', 'Item');
      await tester.pumpAndSettle();

      expect(find.text('Notes'), findsNothing);

      await state.setItemNotes('list', 0, 'Some **markdown** notes.');
      await tester.pumpAndSettle();

      expect(find.text('Notes'), findsOneWidget);
      expect(store.saved['list']!.items.single.notes,
          'Some **markdown** notes.');
    });

    testWidgets('tapping an item opens the note editor', (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);

      await state.createProject('List');
      await state.addItem('list', 'Item');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Item'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
    });
  });

  group('linking projects', () {
    testWidgets('typing [[ opens the picker and inserts a portable link',
        (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);

      await state.createProject('House move');
      await state.createProject('Main Project');
      await state.addItem('main-project', 'Quote doors');
      // The detail pane otherwise defaults to the alphabetically first.
      state.select('main-project');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Quote doors'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'See [[');
      await tester.pumpAndSettle();

      // The picker offers the other project, not the one being edited.
      expect(find.text('Link to project'), findsOneWidget);
      expect(find.text('house-move.md'), findsOneWidget);
      expect(find.text('main-project.md'), findsNothing);

      await tester.tap(find.text('house-move.md'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(
        store.saved['main-project']!.items.single.notes,
        'See [House move](house-move.md)',
      );
    });

    testWidgets('a hand-typed wikilink is rewritten on save', (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);

      await state.createProject('House move');
      await state.createProject('Main Project');
      await state.addItem('main-project', 'Quote doors');
      // The detail pane otherwise defaults to the alphabetically first.
      state.select('main-project');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Quote doors'));
      await tester.pumpAndSettle();

      // Typed in full, so the [[ handler does not fire mid-word.
      await tester.enterText(
        find.byType(TextField).first,
        'Blocked by [[House move]]',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(
        store.saved['main-project']!.items.single.notes,
        'Blocked by [House move](house-move.md)',
      );
    });

    testWidgets('an unresolvable wikilink is left alone', (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);

      await state.createProject('Main Project');
      await state.addItem('main-project', 'Quote doors');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Quote doors'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextField).first,
        'See [[Not A Project]]',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(
        store.saved['main-project']!.items.single.notes,
        'See [[Not A Project]]',
      );
    });
  });

  group('attachment paths', () {
    test('markdown references resolve back to a repo path', () {
      const reference = '../attachments/my-todo/door.png';

      expect(
        AttachmentStore.resolveRepoPath(reference),
        'attachments/my-todo/door.png',
      );
    });

    test('an external image is not treated as an attachment', () {
      expect(
        AttachmentStore.resolveRepoPath('https://example.com/a.png'),
        isNull,
      );
    });

    test('a reference is relative so GitHub renders it', () {
      expect(
        AttachmentStore.markdownPath('my-todo', 'door.png'),
        '../attachments/my-todo/door.png',
      );
    });

    test('filenames are made safe and unique', () {
      expect(AttachmentStore.uniqueFileName('My Photo.png', {}),
          'My-Photo.png');
      expect(
        AttachmentStore.uniqueFileName('a.png', {'a.png'}),
        'a-2.png',
      );
      expect(
        AttachmentStore.uniqueFileName('a.png', {'a.png', 'a-2.png'}),
        'a-3.png',
      );
      expect(
        AttachmentStore.uniqueFileName('/tmp/deep/path.png', {}),
        'path.png',
      );
    });
  });

  group('item model', () {
    test('copyWith leaves untouched fields alone', () {
      const item = ChecklistItem(
        text: 'Thing',
        starred: true,
        notes: 'A note',
      );

      final toggled = item.copyWith(done: true);

      expect(toggled.starred, isTrue);
      expect(toggled.notes, 'A note');
      expect(toggled.text, 'Thing');
    });
  });
}
