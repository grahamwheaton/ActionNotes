import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/home_shell.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

/// Opens an item's note editor with [notes] already in it.
Future<AppState> openNote(
  WidgetTester tester,
  FakeLocalStore store, {
  required String notes,
}) async {
  tester.view.physicalSize = const Size(1280, 900);
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
  await state.addItem('list', 'Item');
  await state.setItemNotes('list', 0, notes);
  await tester.pumpAndSettle();

  await tester.tap(find.text('Item'));
  await tester.pumpAndSettle();
  return state;
}

Finder blockField(int index) => find.byType(TextField).at(index);

/// Puts the caret in a row, then reaches down over [rows] more of them.
Future<void> selectDown(WidgetTester tester, int from, int rows) async {
  await tester.tap(blockField(from));
  await tester.pumpAndSettle();

  await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
  for (var i = 0; i < rows; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
  }
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
}

Future<void> pressCtrl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
  await tester.pumpAndSettle();
}

Future<String> saveAndRead(WidgetTester tester, FakeLocalStore store) async {
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();
  return store.saved['list']!.items.single.notes;
}

void main() {
  testWidgets('shift and down turns a run of lines into checkboxes',
      (tester) async {
    final store = FakeLocalStore();
    await openNote(tester, store, notes: 'One\n\nTwo\n\nThree');

    await selectDown(tester, 0, 2);
    await pressCtrl(tester, LogicalKeyboardKey.keyT);

    expect(
      await saveAndRead(tester, store),
      '- [ ] One\n- [ ] Two\n- [ ] Three',
    );
  });

  testWidgets('a run of lines can become bullets too', (tester) async {
    final store = FakeLocalStore();
    await openNote(tester, store, notes: 'One\n\nTwo');

    await selectDown(tester, 0, 1);
    await pressCtrl(tester, LogicalKeyboardKey.keyL);

    expect(await saveAndRead(tester, store), '- One\n- Two');
  });

  testWidgets('with nothing selected the shortcut still changes one line',
      (tester) async {
    final store = FakeLocalStore();
    await openNote(tester, store, notes: 'One\n\nTwo');

    await tester.tap(blockField(0));
    await tester.pumpAndSettle();
    await pressCtrl(tester, LogicalKeyboardKey.keyT);

    expect(await saveAndRead(tester, store), '- [ ] One\n\nTwo');
  });

  testWidgets('escape gives up the selection', (tester) async {
    final store = FakeLocalStore();
    await openNote(tester, store, notes: 'One\n\nTwo\n\nThree');

    await selectDown(tester, 0, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await pressCtrl(tester, LogicalKeyboardKey.keyT);
    final notes = await saveAndRead(tester, store);

    expect(notes.split('\n').where((l) => l.startsWith('- [ ]')), hasLength(1));
  });

  testWidgets('the selection reaches back up again', (tester) async {
    final store = FakeLocalStore();
    await openNote(tester, store, notes: 'One\n\nTwo\n\nThree');

    // Down over all three, then back up one: the last row drops out.
    await selectDown(tester, 0, 2);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);

    await pressCtrl(tester, LogicalKeyboardKey.keyT);
    final notes = await saveAndRead(tester, store);

    expect(notes.split('\n').where((l) => l.startsWith('- [ ]')), hasLength(2));
  });

  testWidgets('shift and down inside a long line selects text, not rows',
      (tester) async {
    final store = FakeLocalStore();
    await openNote(tester, store, notes: 'One\n\nTwo');

    // Caret at the very start of the first row, so there is still text below
    // it in that same block to select before the row selection takes over.
    await tester.tap(blockField(0));
    await tester.pumpAndSettle();
    final controller = tester.widget<TextField>(blockField(0)).controller!;
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);

    await pressCtrl(tester, LogicalKeyboardKey.keyT);

    // Only the row the caret was in changed.
    expect(await saveAndRead(tester, store), '- [ ] One\n\nTwo');
  });
}
