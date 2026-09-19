import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/home_shell.dart';
import 'package:actionnotes/ui/note_blocks_editor.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/gestures.dart';
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

/// A note's own block, not just any field on screen: with a note open in the
/// desktop pane the sidebar's project search is still there.
Finder blockField(int index) => find
    .descendant(
      of: find.byType(NoteBlocksEditor),
      matching: find.byType(TextField),
    )
    .at(index);

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

/// Stands in for the system clipboard, which a test has none of.
class FakeClipboard {
  String? text;

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            text = (call.arguments as Map)['text'] as String?;
            return null;
          case 'Clipboard.getData':
            return {'text': text};
          default:
            return null;
        }
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }
}

/// Drags with a mouse from the middle of one row's field into another's.
Future<void> dragAcross(WidgetTester tester, int from, int to) async {
  final gesture = await tester.startGesture(
    tester.getCenter(blockField(from)),
    kind: PointerDeviceKind.mouse,
  );
  await gesture.moveTo(tester.getCenter(blockField(to)));
  await tester.pumpAndSettle();
  await gesture.up();
  await tester.pumpAndSettle();
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
  testWidgets('shift and down turns a run of lines into checkboxes', (
    tester,
  ) async {
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

  testWidgets('with nothing selected the shortcut still changes one line', (
    tester,
  ) async {
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

  testWidgets('shift and down inside a long line selects text, not rows', (
    tester,
  ) async {
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

  group('across lines', () {
    testWidgets('dragging from one line into another selects the lines', (
      tester,
    ) async {
      final store = FakeLocalStore();
      await openNote(tester, store, notes: 'One\n\nTwo\n\nThree');

      await dragAcross(tester, 0, 2);
      await pressCtrl(tester, LogicalKeyboardKey.keyT);

      expect(
        await saveAndRead(tester, store),
        '- [ ] One\n- [ ] Two\n- [ ] Three',
      );
    });

    testWidgets('dragging upwards selects just the same', (tester) async {
      final store = FakeLocalStore();
      await openNote(tester, store, notes: 'One\n\nTwo\n\nThree');

      await dragAcross(tester, 2, 1);
      await pressCtrl(tester, LogicalKeyboardKey.keyT);

      expect(await saveAndRead(tester, store), 'One\n\n- [ ] Two\n- [ ] Three');
    });

    testWidgets('a drag back into its own line hands selecting back to it', (
      tester,
    ) async {
      final store = FakeLocalStore();
      await openNote(tester, store, notes: 'One\n\nTwo');

      final gesture = await tester.startGesture(
        tester.getCenter(blockField(0)),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(tester.getCenter(blockField(1)));
      await tester.pumpAndSettle();
      await gesture.moveTo(tester.getCenter(blockField(0)));
      await tester.pumpAndSettle();
      await gesture.up();
      await tester.pumpAndSettle();

      await pressCtrl(tester, LogicalKeyboardKey.keyT);

      // Only the row the drag started and ended in.
      expect(await saveAndRead(tester, store), '- [ ] One\n\nTwo');
    });

    // A touch drag on a note is a scroll. Taking it over would cost more than
    // it gave, so it is deliberately left alone.
    testWidgets('a touch drag selects nothing', (tester) async {
      final store = FakeLocalStore();
      await openNote(tester, store, notes: 'One\n\nTwo\n\nThree');

      await tester.tap(blockField(0));
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(blockField(0)),
      );
      await gesture.moveTo(tester.getCenter(blockField(2)));
      await tester.pumpAndSettle();
      await gesture.up();
      await tester.pumpAndSettle();

      await pressCtrl(tester, LogicalKeyboardKey.keyT);

      expect(await saveAndRead(tester, store), '- [ ] One\n\nTwo\n\nThree');
    });

    testWidgets('copying a selection puts its markdown on the clipboard', (
      tester,
    ) async {
      final clipboard = FakeClipboard();
      final store = FakeLocalStore();
      await openNote(tester, store, notes: '# Title\n\nOne\n\n- Two');
      clipboard.install(tester);

      await selectDown(tester, 0, 2);
      await pressCtrl(tester, LogicalKeyboardKey.keyC);

      // Markdown, not flattened text: pasting it elsewhere keeps the heading
      // and the bullet.
      expect(clipboard.text, '# Title\n\nOne\n\n- Two');
    });

    testWidgets('copying takes only the selected lines', (tester) async {
      final clipboard = FakeClipboard();
      final store = FakeLocalStore();
      await openNote(tester, store, notes: 'One\n\nTwo\n\nThree');
      clipboard.install(tester);

      await selectDown(tester, 0, 1);
      await pressCtrl(tester, LogicalKeyboardKey.keyC);

      expect(clipboard.text, 'One\n\nTwo');
    });

    testWidgets('cutting copies the lines and takes them out', (tester) async {
      final clipboard = FakeClipboard();
      final store = FakeLocalStore();
      await openNote(tester, store, notes: 'One\n\nTwo\n\nThree');
      clipboard.install(tester);

      await selectDown(tester, 0, 1);
      await pressCtrl(tester, LogicalKeyboardKey.keyX);
      await tester.pumpAndSettle();

      expect(clipboard.text, 'One\n\nTwo');
      expect(await saveAndRead(tester, store), 'Three');
    });

    testWidgets('backspace over a selection takes the lines', (tester) async {
      final store = FakeLocalStore();
      await openNote(tester, store, notes: 'One\n\nTwo\n\nThree');

      await selectDown(tester, 1, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();

      expect(await saveAndRead(tester, store), 'One');
    });

    testWidgets('taking every line leaves somewhere to type', (tester) async {
      final store = FakeLocalStore();
      await openNote(tester, store, notes: 'One\n\nTwo');

      await selectDown(tester, 0, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(NoteBlocksEditor),
          matching: find.byType(TextField),
        ),
        findsOneWidget,
      );
      expect(await saveAndRead(tester, store), '');
    });

    testWidgets('ctrl and A take the whole note', (tester) async {
      final clipboard = FakeClipboard();
      final store = FakeLocalStore();
      await openNote(tester, store, notes: 'One\n\nTwo\n\nThree');
      clipboard.install(tester);

      await tester.tap(blockField(1));
      await tester.pumpAndSettle();
      await pressCtrl(tester, LogicalKeyboardKey.keyA);
      await pressCtrl(tester, LogicalKeyboardKey.keyC);

      expect(clipboard.text, 'One\n\nTwo\n\nThree');
    });

    testWidgets('a selection undoes in one step', (tester) async {
      final store = FakeLocalStore();
      await openNote(tester, store, notes: 'One\n\nTwo\n\nThree');

      await selectDown(tester, 0, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();

      await pressCtrl(tester, LogicalKeyboardKey.keyZ);

      expect(await saveAndRead(tester, store), 'One\n\nTwo\n\nThree');
    });
  });
  group('an arrow key at the edge of a row', () {
    testWidgets('down carries on into the row below', (tester) async {
      await openNote(tester, FakeLocalStore(), notes: 'First\nSecond');

      await tester.tap(blockField(0));
      await tester.pumpAndSettle();
      _caretAt(tester, 0, 'First'.length);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      // The note is one piece of writing even though every line is its own
      // field, so the caret walks through it rather than stopping dead.
      expect(_focused(tester, 1), isTrue);
      expect(_caret(tester, 1), 0);
    });

    testWidgets('up goes back to the end of the row above', (tester) async {
      await openNote(tester, FakeLocalStore(), notes: 'First\nSecond');

      await tester.tap(blockField(1));
      await tester.pumpAndSettle();
      _caretAt(tester, 1, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();

      expect(_focused(tester, 0), isTrue);
      expect(_caret(tester, 0), 'First'.length);
    });

    testWidgets('the last row keeps the caret rather than losing it', (
      tester,
    ) async {
      await openNote(tester, FakeLocalStore(), notes: 'First\nSecond');

      await tester.tap(blockField(1));
      await tester.pumpAndSettle();
      _caretAt(tester, 1, 'Second'.length);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      expect(_focused(tester, 1), isTrue);
    });
  });
}

void _caretAt(WidgetTester tester, int row, int offset) {
  final field = tester.widget<TextField>(blockField(row));
  field.controller!.selection = TextSelection.collapsed(offset: offset);
}

bool _focused(WidgetTester tester, int row) =>
    tester.widget<TextField>(blockField(row)).focusNode!.hasFocus;

int _caret(WidgetTester tester, int row) =>
    tester.widget<TextField>(blockField(row)).controller!.selection.baseOffset;
