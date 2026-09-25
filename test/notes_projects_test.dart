import 'package:actionnotes/markdown/project_markdown.dart';
import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/checklist_view.dart';
import 'package:actionnotes/ui/context_menu.dart';
import 'package:actionnotes/ui/note_blocks_editor.dart';
import 'package:actionnotes/ui/project_notes_view.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:actionnotes/ui/touch_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

Future<AppState> pumpProject(
  WidgetTester tester,
  FakeLocalStore store, {
  bool touch = false,
}) async {
  TouchInput.debugOverride = touch;
  addTearDown(() => TouchInput.debugOverride = null);

  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final state = newTestState(store);
  await state.init();
  await state.createProject('List');
  await addItemsInOrder(state, 'list', ['Buy milk']);

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const ChecklistView(slug: 'list'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

void main() {
  group('the mode in the file', () {
    test('a checklist writes no mode at all, so its file does not change', () {
      final project = Project(slug: 'list', title: 'List');
      expect(ProjectMarkdown.serialize(project), isNot(contains('mode:')));
    });

    test('a notes project says so, and reads back', () {
      final project = Project(
        slug: 'list',
        title: 'List',
        notes: 'Just some prose.',
        mode: ProjectMode.notes,
      );
      final markdown = ProjectMarkdown.serialize(project);
      expect(markdown, contains('mode: notes'));

      final again = ProjectMarkdown.parse(markdown, slug: 'list');
      expect(again.mode, ProjectMode.notes);
      expect(again.notes, 'Just some prose.');
    });

    test('an unknown mode falls back to a checklist rather than failing', () {
      final project = ProjectMarkdown.parse(
        '---\ntitle: List\nmode: spreadsheet\n---\n\n# List\n',
        slug: 'list',
      );
      expect(project.mode, ProjectMode.tasks);
    });

    test('items survive a project being turned into notes and back', () {
      final original = ProjectMarkdown.parse(
        '---\ntitle: List\n---\n\n# List\n\n- [ ] Buy milk\n  a note\n',
        slug: 'list',
      );

      final asNotes = original.copyWith(mode: ProjectMode.notes);
      final roundTripped = ProjectMarkdown.parse(
        ProjectMarkdown.serialize(asNotes),
        slug: 'list',
      );
      expect(roundTripped.items.single.text, 'Buy milk');
      expect(roundTripped.items.single.notes, 'a note');

      final back = roundTripped.copyWith(mode: ProjectMode.tasks);
      expect(
        ProjectMarkdown.serialize(back).trim(),
        ProjectMarkdown.serialize(original).trim(),
      );
    });
  });

  group('a notes project on screen', () {
    testWidgets('opens as a document, not a checklist', (tester) async {
      final state = await pumpProject(tester, FakeLocalStore());

      await state.setMode('list', ProjectMode.notes);
      await tester.pumpAndSettle();

      expect(find.byType(ProjectNotesView), findsOneWidget);
      // No add box and no checkbox: this is not a list.
      expect(find.byType(Checkbox), findsNothing);
      expect(find.text('Add an item'), findsNothing);
    });

    testWidgets('what is typed reaches the project body', (tester) async {
      final store = FakeLocalStore();
      final state = await pumpProject(tester, store);
      await state.setMode('list', ProjectMode.notes);
      await tester.pumpAndSettle();

      await tester.enterText(
        find
            .descendant(
              of: find.byType(NoteBlocksEditor),
              matching: find.byType(TextField),
            )
            .first,
        'Some prose about the project',
      );
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();

      expect(
        state.projectBySlug('list')!.notes,
        contains('Some prose about the project'),
      );
    });

    testWidgets('an update saves typing before the autosave delay', (
      tester,
    ) async {
      final store = FakeLocalStore();
      final state = await pumpProject(tester, store);
      await state.setMode('list', ProjectMode.notes);
      await tester.pumpAndSettle();
      await tester.enterText(
        find
            .descendant(
              of: find.byType(NoteBlocksEditor),
              matching: find.byType(TextField),
            )
            .first,
        'typed just before restart',
      );
      await state.prepareForUpdate();
      expect(store.saved['list']!.notes, contains('typed just before restart'));
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });

    testWidgets('the menu offers the way back to a checklist', (tester) async {
      final state = await pumpProject(tester, FakeLocalStore());
      await state.setMode('list', ProjectMode.notes);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('Turn into a checklist'), findsOneWidget);
    });

    testWidgets('and a checklist offers the way to notes', (tester) async {
      await pumpProject(tester, FakeLocalStore());

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('Turn into notes'), findsOneWidget);
    });
  });

  group('the notes marker on a row', () {
    testWidgets('is gone on a phone, and in the menu instead', (tester) async {
      await pumpProject(tester, FakeLocalStore(), touch: true);

      expect(find.byIcon(Icons.notes_outlined), findsNothing);

      await tester.tap(find.byType(ItemMenuButton));
      await tester.pumpAndSettle();
      expect(find.text('Add notes'), findsOneWidget);
      expect(find.text('Open in editor'), findsOneWidget);
    });

    testWidgets('opening the notes from the menu opens them in place', (
      tester,
    ) async {
      await pumpProject(tester, FakeLocalStore(), touch: true);

      await tester.tap(find.byType(ItemMenuButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add notes'));
      await tester.pumpAndSettle();

      expect(find.byType(NoteBlocksEditor), findsOneWidget);
    });

    testWidgets('a mouse keeps the marker on the row', (tester) async {
      await pumpProject(tester, FakeLocalStore());
      expect(find.byIcon(Icons.notes_outlined), findsOneWidget);
    });
  });
}
