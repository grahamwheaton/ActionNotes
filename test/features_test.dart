import 'package:actionnotes/models/checklist_item.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/storage/attachment_store.dart';
import 'package:actionnotes/ui/home_shell.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
      await addItemsInOrder(state, 'my-todo', ['Quote brick undersides', 'Reception', 'Bedrooms']);
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
      await addItemsInOrder(state, 'list', ['First', 'Second', 'Third']);
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
      await addItemsInOrder(state, 'list', ['A', 'B', 'C', 'D']);
      // B and D complete, so open items are A (slot 0) and C (slot 2).
      await state.toggleItem('list', 1);
      await state.toggleItem('list', 3);

      // Move C before A.
      await state.reorderSlots('list', [0, 2], 1, 0);

      final items = store.saved['list']!.items;
      expect(items.map((i) => i.text), ['C', 'B', 'A', 'D']);
      expect(items.map((i) => i.done), [false, true, false, true]);
    });

    test('reordering with nothing completed behaves as a plain move', () async {
      final store = FakeLocalStore();
      final state = newTestState(store);
      await state.init();

      await state.createProject('List');
      await addItemsInOrder(state, 'list', ['A', 'B', 'C']);

      await state.reorderSlots('list', [0, 1, 2], 0, 2);

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

    testWidgets('a narrow window uses the phone layout, not two panes',
        (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store, size: const Size(420, 900));

      await state.createProject('Alpha');
      await state.addItem('alpha', 'Alpha item');
      await tester.pumpAndSettle();

      // The phone layout offers a floating New project button and shows the
      // list alone — the checklist arrives as a pushed screen.
      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Alpha item'), findsNothing);
    });

    testWidgets('a wide window shows a detail pane and no floating button',
        (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);

      await state.createProject('Alpha');
      await state.addItem('alpha', 'Alpha item');
      await tester.pumpAndSettle();

      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.text('Alpha item'), findsOneWidget);
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

  group('leaving the note editor', () {
    Future<AppState> openNote(
      WidgetTester tester,
      FakeLocalStore store, {
      Size size = const Size(1280, 900),
    }) async {
      final state = await pumpShell(tester, store, size: size);
      await state.createProject('List');
      await state.addItem('list', 'Quote doors');
      await tester.pumpAndSettle();

      // On a phone the checklist is a pushed screen, not a detail pane.
      if (size.width < 720) {
        await tester.tap(find.text('List'));
        await tester.pumpAndSettle();
      }

      await tester.tap(find.text('Quote doors'));
      await tester.pumpAndSettle();
      return state;
    }

    testWidgets('pressing back saves the note', (tester) async {
      final store = FakeLocalStore();
      await openNote(tester, store);

      await tester.enterText(find.byType(TextField).first, 'Typed then back.');
      await tester.pumpAndSettle();

      // The app bar's back arrow, the thing a person actually presses.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(store.saved['list']!.items.single.notes, 'Typed then back.');
    });

    testWidgets('the system back gesture saves too', (tester) async {
      final store = FakeLocalStore();
      await openNote(tester, store, size: const Size(420, 900));

      await tester.enterText(find.byType(TextField).first, 'Android back.');
      await tester.pumpAndSettle();

      // What Android's back gesture delivers to the engine.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(store.saved['list']!.items.single.notes, 'Android back.');
    });

    testWidgets('Save still closes and writes', (tester) async {
      final store = FakeLocalStore();
      await openNote(tester, store);

      await tester.enterText(find.byType(TextField).first, 'Saved.');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(store.saved['list']!.items.single.notes, 'Saved.');
      expect(find.text('Quote doors'), findsWidgets);
    });

    testWidgets('leaving an untouched note writes nothing', (tester) async {
      final store = FakeLocalStore();
      await openNote(tester, store);

      final before = store.saved['list']!.updated;
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      // No edit means no new revision, so nothing to push.
      expect(store.saved['list']!.updated, before);
      expect(store.saved['list']!.items.single.notes, isEmpty);
    });
  });

  group('the note editor writes markdown', () {
    Future<AppState> openNoteOn(
      WidgetTester tester,
      FakeLocalStore store,
    ) async {
      final state = await pumpShell(tester, store);
      await state.createProject('List');
      await state.addItem('list', 'Item');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Item'));
      await tester.pumpAndSettle();
      return state;
    }

    Finder blockField(int index) => find.byType(TextField).at(index);

    testWidgets('typing "# " makes a heading and takes the marker away',
        (tester) async {
      final store = FakeLocalStore();
      await openNoteOn(tester, store);

      await tester.enterText(blockField(0), '# ');
      await tester.pumpAndSettle();

      // The marker is gone from the text; the block carries it instead.
      expect(tester.widget<TextField>(blockField(0)).controller!.text, '');

      await tester.enterText(blockField(0), 'A heading');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(store.saved['list']!.items.single.notes, '# A heading');
    });

    testWidgets('typing "- " makes a bullet', (tester) async {
      final store = FakeLocalStore();
      await openNoteOn(tester, store);

      await tester.enterText(blockField(0), '- ');
      await tester.pumpAndSettle();
      await tester.enterText(blockField(0), 'a point');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(store.saved['list']!.items.single.notes, '- a point');
    });

    testWidgets('a heading and a paragraph are separated in the file',
        (tester) async {
      final store = FakeLocalStore();
      await openNoteOn(tester, store);

      await tester.enterText(blockField(0), '# ');
      await tester.pumpAndSettle();
      await tester.enterText(blockField(0), 'Title');
      await tester.pumpAndSettle();

      // Enter splits the block, leaving a paragraph below the heading.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.enterText(blockField(1), 'Body text.');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(
        store.saved['list']!.items.single.notes,
        '# Title\n\nBody text.',
      );
    });

    testWidgets('an existing note opens as its blocks', (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);
      await state.createProject('List');
      await state.addItem('list', 'Item');
      await state.setItemNotes(
        'list',
        0,
        '# Heading\n\nA paragraph.\n\n- one\n- two',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Item'));
      await tester.pumpAndSettle();

      // Four editable blocks, each holding its text without its marker.
      expect(find.byType(TextField), findsNWidgets(4));
      expect(
        tester.widget<TextField>(blockField(0)).controller!.text,
        'Heading',
      );
      expect(
        tester.widget<TextField>(blockField(2)).controller!.text,
        'one',
      );
    });

    testWidgets('reopening a note does not change the file', (tester) async {
      final store = FakeLocalStore();
      const original = '# Heading\n\nA paragraph.\n\n- one\n- two';

      final state = await pumpShell(tester, store);
      await state.createProject('List');
      await state.addItem('list', 'Item');
      await state.setItemNotes('list', 0, original);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Item'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(store.saved['list']!.items.single.notes, original);
    });
  });

  group('new items', () {
    testWidgets('go to the top of the list, not the bottom', (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);
      await state.createProject('List');
      await tester.pumpAndSettle();

      for (final text in ['Oldest', 'Middle', 'Newest']) {
        await tester.enterText(
          find.widgetWithText(TextField, 'Add an item'),
          text,
        );
        await tester.tap(find.byTooltip('Add item'));
        await tester.pumpAndSettle();
      }

      // Newest first, in the file as well as on screen.
      expect(
        store.saved['list']!.items.map((i) => i.text),
        ['Newest', 'Middle', 'Oldest'],
      );
      expect(
        tester.getTopLeft(find.text('Newest')).dy,
        lessThan(tester.getTopLeft(find.text('Oldest')).dy),
      );
    });
  });

  group('a long task title', () {
    testWidgets('wraps instead of being cut off', (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);

      const long = 'I want full markdown syntax on the note - at the moment '
          'headers not working? I do not want a textbox and then a preview';

      await state.createProject('List');
      await state.addItem('list', long);
      await tester.pumpAndSettle();

      await tester.tap(find.text(long));
      await tester.pumpAndSettle();

      final title = tester.widget<Text>(
        find.descendant(of: find.byType(AppBar), matching: find.text(long)),
      );

      expect(title.maxLines, greaterThan(1));
    });
  });

  group('starred items pin to the top', () {
    testWidgets('a starred item is drawn above the unstarred ones',
        (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);

      await state.createProject('List');
      await addItemsInOrder(state, 'list', ['First', 'Second', 'Third']);
      await state.toggleStar('list', 2);
      await tester.pumpAndSettle();

      final starredY = tester.getTopLeft(find.text('Third')).dy;
      final firstY = tester.getTopLeft(find.text('First')).dy;
      expect(starredY, lessThan(firstY));
    });

    testWidgets('pinning does not reorder the file', (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);

      await state.createProject('List');
      await addItemsInOrder(state, 'list', ['First', 'Second', 'Third']);
      await state.toggleStar('list', 2);
      await tester.pumpAndSettle();

      // Only the view changes; the markdown keeps the order it had.
      expect(
        store.saved['list']!.items.map((i) => i.text),
        ['First', 'Second', 'Third'],
      );
    });

    testWidgets('unstarring drops it back among the others', (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);

      await state.createProject('List');
      await addItemsInOrder(state, 'list', ['First', 'Second']);
      await state.toggleStar('list', 1);
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.text('Second')).dy,
        lessThan(tester.getTopLeft(find.text('First')).dy),
      );

      await state.toggleStar('list', 1);
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.text('First')).dy,
        lessThan(tester.getTopLeft(find.text('Second')).dy),
      );
    });

    test('reordering one group leaves the other groups alone', () async {
      final store = FakeLocalStore();
      final state = newTestState(store);
      await state.init();

      await state.createProject('List');
      await addItemsInOrder(state, 'list', ['A', 'B', 'C', 'D']);
      await state.toggleStar('list', 1); // B starred
      await state.toggleStar('list', 3); // D starred

      // Swap the two starred items, which sit at slots 1 and 3.
      await state.reorderSlots('list', [1, 3], 1, 0);

      final items = store.saved['list']!.items;
      expect(items.map((i) => i.text), ['A', 'D', 'C', 'B']);
      expect(items.map((i) => i.starred), [false, true, false, true]);
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
