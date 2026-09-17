import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/checklist_view.dart';
import 'package:actionnotes/ui/note_blocks_editor.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

/// Drives the checklist on a wide surface, where items and their inline notes
/// are both on screen at once.
Future<AppState> pumpChecklist(
  WidgetTester tester,
  FakeLocalStore store,
) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final state = newTestState(store);
  await state.init();
  await state.createProject('List');
  await addItemsInOrder(state, 'list', ['First', 'Second']);
  // Both start with notes, so the toggle reads "Show notes" on each.
  await state.setItemNotes('list', 0, 'first note');
  await state.setItemNotes('list', 1, 'second note');

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

/// The inline note's own text field, rather than the add-item bar.
Finder inlineNoteField() => find.descendant(
      of: find.byType(NoteBlocksEditor),
      matching: find.byType(TextField),
    );

/// Opens the inline note editor on the row showing [itemText].
Future<void> openNotesOn(WidgetTester tester, String itemText) async {
  final row = find.ancestor(
    of: find.text(itemText),
    matching: find.byType(Row),
  );
  await tester.tap(
    find.descendant(of: row.first, matching: find.byTooltip('Show notes')),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('an inline note edit still in hand', () {
    testWidgets('is written to its own item after a new item is added',
        (tester) async {
      final store = FakeLocalStore();
      final state = await pumpChecklist(tester, store);

      await openNotesOn(tester, 'Second');

      // Type into Second's note, but do not wait for the write to settle.
      await tester.enterText(inlineNoteField().first, 'belongs to Second');
      await tester.pump(const Duration(milliseconds: 100));

      // Adding an item prepends it, so every index shifts by one. An edit
      // held by index would land on the wrong row from here.
      await state.addItem('list', 'Newest');
      await tester.pump(const Duration(seconds: 1));

      final items = store.saved['list']!.items;
      final byText = {for (final item in items) item.text: item.notes};

      expect(byText['Second'], 'belongs to Second');
      expect(byText['First'], 'first note', reason: 'First was never edited');
      expect(byText['Newest'], isEmpty, reason: 'Newest was never edited');
    });

    testWidgets('survives the row moving, rather than being misfiled',
        (tester) async {
      final store = FakeLocalStore();
      final state = await pumpChecklist(tester, store);

      await openNotesOn(tester, 'First');
      await tester.enterText(inlineNoteField().first, 'about First');
      await tester.pump(const Duration(milliseconds: 100));

      // Reorder while the edit is in hand: First moves to the bottom.
      await state.reorderSlots('list', [0, 1], 0, 1);
      await tester.pump(const Duration(seconds: 1));

      final byText = {
        for (final item in store.saved['list']!.items) item.text: item.notes,
      };

      expect(byText['First'], 'about First');
      expect(byText['Second'], 'second note');
    });

    testWidgets('is dropped, not misfiled, when its item is deleted',
        (tester) async {
      final store = FakeLocalStore();
      final state = await pumpChecklist(tester, store);

      await openNotesOn(tester, 'Second');
      await tester.enterText(inlineNoteField().first, 'about Second');
      await tester.pump(const Duration(milliseconds: 100));

      // 'Second' sits at index 1; removing it leaves only 'First'.
      await state.removeItem('list', 1);
      await tester.pump(const Duration(seconds: 1));

      final items = store.saved['list']!.items;
      expect(items.map((i) => i.text), ['First']);
      expect(
        items.single.notes,
        'first note',
        reason: "the deleted item's note must not land on the survivor",
      );
    });
  });
}
