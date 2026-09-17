import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/checklist_view.dart';
import 'package:actionnotes/ui/note_blocks_editor.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

Future<AppState> pumpList(WidgetTester tester, List<String> items) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final state = newTestState(FakeLocalStore());
  await state.init();
  await state.createProject('List');
  if (items.isNotEmpty) await addItemsInOrder(state, 'list', items);

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
  group('adding an item', () {
    testWidgets('Enter adds it unstarred', (tester) async {
      final state = await pumpList(tester, []);

      await tester.enterText(find.byType(TextField).last, 'Ordinary');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(state.projects.single.items.single.text, 'Ordinary');
      expect(state.projects.single.items.single.starred, isFalse);
    });

    testWidgets('Ctrl+Enter adds it starred', (tester) async {
      final state = await pumpList(tester, []);

      await tester.enterText(find.byType(TextField).last, 'Urgent');
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pumpAndSettle();

      final item = state.projects.single.items.single;
      expect(item.text, 'Urgent');
      expect(item.starred, isTrue);
    });

    testWidgets('Ctrl+Enter on an empty box adds nothing', (tester) async {
      final state = await pumpList(tester, []);

      await tester.tap(find.byType(TextField).last);
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pumpAndSettle();

      expect(state.projects.single.items, isEmpty);
    });

    testWidgets('the box says what Ctrl+Enter does', (tester) async {
      await pumpList(tester, []);
      expect(find.text('Ctrl+Enter adds it starred'), findsOneWidget);
    });
  });

  group('alt and the notes disclosure', () {
    Future<void> altTap(WidgetTester tester, Finder target) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.tap(target);
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    }

    testWidgets('opens every note in the project', (tester) async {
      await pumpList(tester, ['One', 'Two', 'Three']);

      expect(find.byType(NoteBlocksEditor), findsNothing);

      await altTap(tester, find.byTooltip('Add notes').first);

      expect(find.byType(NoteBlocksEditor), findsNWidgets(3));
    });

    testWidgets('and closes them all again', (tester) async {
      await pumpList(tester, ['One', 'Two', 'Three']);

      await altTap(tester, find.byTooltip('Add notes').first);
      expect(find.byType(NoteBlocksEditor), findsNWidgets(3));

      // Alt-clicking an open one closes the lot, rather than each row
      // flipping to its own opposite.
      await altTap(tester, find.byTooltip('Hide notes').first);

      expect(find.byType(NoteBlocksEditor), findsNothing);
    });

    testWidgets('without alt it is still one row', (tester) async {
      await pumpList(tester, ['One', 'Two', 'Three']);

      await tester.tap(find.byTooltip('Add notes').first);
      await tester.pumpAndSettle();

      expect(find.byType(NoteBlocksEditor), findsOneWidget);
    });

    testWidgets('alt-clicking a closed row opens them all, even with one open',
        (tester) async {
      await pumpList(tester, ['One', 'Two', 'Three']);

      await tester.tap(find.byTooltip('Add notes').first);
      await tester.pumpAndSettle();
      expect(find.byType(NoteBlocksEditor), findsOneWidget);

      await altTap(tester, find.byTooltip('Add notes').first);

      expect(find.byType(NoteBlocksEditor), findsNWidgets(3));
    });
  });
}
