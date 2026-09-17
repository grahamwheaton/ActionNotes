import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/checklist_view.dart';
import 'package:actionnotes/ui/home_shell.dart';
import 'package:actionnotes/ui/note_blocks_editor.dart';
import 'package:actionnotes/ui/note_editor.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

/// Opens the shell with two projects, the first holding two items.
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

  await state.createProject('List');
  await addItemsInOrder(state, 'list', ['First item', 'Second item']);
  await state.createProject('Other');
  state.select('list');
  await tester.pumpAndSettle();
  return state;
}

Finder noteField() => find
    .descendant(
      of: find.byType(NoteBlocksEditor),
      matching: find.byType(TextField),
    )
    .first;

void main() {
  group('a note on a wide window', () {
    testWidgets('opens beside the sidebar rather than over it', (tester) async {
      await pumpShell(tester, FakeLocalStore());

      await tester.tap(find.text('First item'));
      await tester.pumpAndSettle();

      expect(find.byType(NoteEditor), findsOneWidget);
      // The point of the change: the projects are still there to click.
      expect(find.byType(ProjectSidebar), findsOneWidget);
      expect(find.text('Other'), findsOneWidget);
      // And the checklist has given the pane up.
      expect(find.byType(ChecklistView), findsNothing);
    });

    testWidgets('names the item it is editing, without its tag markers',
        (tester) async {
      final state = await pumpShell(tester, FakeLocalStore());
      await state.editItem('list', 0, 'First item [bug]');
      await tester.pumpAndSettle();

      await tester.tap(find.text('First item'));
      await tester.pumpAndSettle();

      expect(find.text('First item'), findsOneWidget);
      expect(find.text('First item [bug]'), findsNothing);
    });

    testWidgets('back returns to the checklist and saves', (tester) async {
      final store = FakeLocalStore();
      await pumpShell(tester, store);

      await tester.tap(find.text('First item'));
      await tester.pumpAndSettle();
      await tester.enterText(noteField(), 'Typed in the pane.');
      await tester.pumpAndSettle();

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(find.byType(NoteEditor), findsNothing);
      expect(find.byType(ChecklistView), findsOneWidget);
      expect(store.saved['list']!.items.first.notes, 'Typed in the pane.');
    });

    testWidgets('Save writes and closes just the same', (tester) async {
      final store = FakeLocalStore();
      await pumpShell(tester, store);

      await tester.tap(find.text('First item'));
      await tester.pumpAndSettle();
      await tester.enterText(noteField(), 'Saved from the pane.');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.byType(NoteEditor), findsNothing);
      expect(store.saved['list']!.items.first.notes, 'Saved from the pane.');
    });

    // A route is left by popping, which saves on the way out. A pane can be
    // replaced by anything that changes the detail side, so it cannot wait
    // for a close that may never come.
    testWidgets('an edit saves itself without being told to', (tester) async {
      final store = FakeLocalStore();
      await pumpShell(tester, store);

      await tester.tap(find.text('First item'));
      await tester.pumpAndSettle();
      await tester.enterText(noteField(), 'Left alone.');
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(store.saved['list']!.items.first.notes, 'Left alone.');
      // Still open: saving is not leaving.
      expect(find.byType(NoteEditor), findsOneWidget);
    });

    testWidgets('choosing another project closes the note', (tester) async {
      final store = FakeLocalStore();
      final state = await pumpShell(tester, store);

      await tester.tap(find.text('First item'));
      await tester.pumpAndSettle();
      await tester.enterText(noteField(), 'Half a thought.');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Other'));
      await tester.pumpAndSettle();

      expect(find.byType(NoteEditor), findsNothing);
      expect(state.openNote, isNull);
      // The pane cannot save on the way out, so the autosave has to have
      // covered it: what was typed is not lost.
      expect(store.saved['list']!.items.first.notes, 'Half a thought.');
    });

    testWidgets('opening another item shows that item\'s note', (tester) async {
      final state = await pumpShell(tester, FakeLocalStore());
      await state.setItemNotes('list', 0, 'First note');
      await state.setItemNotes('list', 1, 'Second note');
      await tester.pumpAndSettle();

      await tester.tap(find.text('First item'));
      await tester.pumpAndSettle();
      expect(find.text('First note'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second item'));
      await tester.pumpAndSettle();

      expect(find.text('Second note'), findsOneWidget);
      expect(find.text('First note'), findsNothing);
    });

    // An index only means something against the list it came from.
    testWidgets('removing the item closes the note rather than pointing at '
        'whatever moved into its place', (tester) async {
      final state = await pumpShell(tester, FakeLocalStore());

      await tester.tap(find.text('First item'));
      await tester.pumpAndSettle();
      expect(state.openNote, isNotNull);

      await state.removeItem('list', 0);
      await tester.pumpAndSettle();

      expect(state.openNote, isNull);
      expect(find.byType(NoteEditor), findsNothing);
      expect(find.text('Second item'), findsOneWidget);
    });

    testWidgets('deleting the project closes the note', (tester) async {
      final state = await pumpShell(tester, FakeLocalStore());

      await tester.tap(find.text('First item'));
      await tester.pumpAndSettle();

      await state.deleteProject('list');
      await tester.pumpAndSettle();

      expect(state.openNote, isNull);
      expect(find.byType(NoteEditor), findsNothing);
    });
  });

  group('a note on a narrow window', () {
    testWidgets('is still a screen of its own', (tester) async {
      final store = FakeLocalStore();
      await pumpShell(tester, store, size: const Size(420, 900));

      await tester.tap(find.text('List'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('First item'));
      await tester.pumpAndSettle();

      expect(find.byType(NoteEditor), findsOneWidget);
      // Nothing to keep beside it, so the editor has the screen.
      expect(find.byType(ProjectSidebar), findsNothing);
      expect(find.text('Other'), findsNothing);
    });
  });
}
