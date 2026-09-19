import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/checklist_view.dart';
import 'package:actionnotes/ui/context_menu.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:actionnotes/ui/touch_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

Future<AppState> pumpList(WidgetTester tester, {bool touch = true}) async {
  TouchInput.debugOverride = touch;
  addTearDown(() => TouchInput.debugOverride = null);

  tester.view.physicalSize = const Size(420, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final state = newTestState(FakeLocalStore());
  await state.init();
  await state.createProject('List');

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
  group('knowing a row has something under it', () {
    testWidgets('an item with notes carries a marker', (tester) async {
      final state = await pumpList(tester);
      await state.addItem('list', 'Buy milk');
      await state.setItemNotes('list', 0, 'from the corner shop');
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.notes), findsOneWidget);
    });

    testWidgets('an item without notes carries none, or it would say nothing', (
      tester,
    ) async {
      final state = await pumpList(tester);
      await state.addItem('list', 'Buy milk');
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.notes), findsNothing);
    });

    testWidgets('the marker turns over when the notes are open', (
      tester,
    ) async {
      final state = await pumpList(tester);
      await state.addItem('list', 'Buy milk');
      await state.setItemNotes('list', 0, 'from the corner shop');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Buy milk'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.notes), findsNothing);
      expect(find.byIcon(Icons.expand_less), findsOneWidget);
    });
  });

  group('room for the text', () {
    testWidgets('the star sits close to the menu, not a button apart', (
      tester,
    ) async {
      final state = await pumpList(tester);
      await state.addItem('list', 'Buy milk');
      await tester.pumpAndSettle();

      final star = tester.getRect(find.byIcon(Icons.star_border));
      final menu = tester.getRect(find.byType(ItemMenuButton));

      // Touching distance: a default icon button would leave a 48-pixel box
      // around a 20-pixel star and push the title in by most of a word.
      expect(menu.left - star.right, lessThan(14));
    });

    testWidgets('the notes under a row start near the edge on a phone', (
      tester,
    ) async {
      final state = await pumpList(tester);
      await state.addItem('list', 'Buy milk');
      await state.setItemNotes('list', 0, 'a note');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Buy milk'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      final title = tester.getRect(find.text('Buy milk'));
      final note = tester.getRect(find.text('a note'));

      // Left of where the title starts: the indent that lined notes up under
      // the title cost most of a word per line on a narrow screen.
      expect(note.left, lessThan(title.left));
    });

    testWidgets('a mouse keeps the notes lined up under the title', (
      tester,
    ) async {
      final state = await pumpList(tester, touch: false);
      await state.addItem('list', 'Buy milk');
      await state.setItemNotes('list', 0, 'a note');
      await tester.pumpAndSettle();

      // The marker button at the end of the row, which a desktop keeps.
      await tester.tap(find.byTooltip('Show notes'));
      await tester.pumpAndSettle();

      final title = tester.getRect(find.text('Buy milk'));
      final note = tester.getRect(find.text('a note'));
      expect(note.left, greaterThanOrEqualTo(title.left - 1));
    });
  });

  group('a section', () {
    testWidgets('has a card of its own, and a name typed in place', (
      tester,
    ) async {
      final state = await pumpList(tester);
      await state.addBlock('list', 'Shopping');
      await tester.pumpAndSettle();

      // The name is a field, not a label behind a Rename dialog.
      final field = find.widgetWithText(TextField, 'Shopping');
      expect(field, findsOneWidget);

      await tester.enterText(field, 'Groceries');
      await tester.pumpAndSettle();
      // Committed when it loses focus, not per keystroke — a rename carries
      // the section's items with it.
      expect(state.projects.single.blocks.single.title, 'Shopping');

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(state.projects.single.blocks.single.title, 'Groceries');
    });

    testWidgets('an empty name is refused rather than written', (tester) async {
      final state = await pumpList(tester);
      await state.addBlock('list', 'Shopping');
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Shopping'), '  ');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      expect(state.projects.single.blocks.single.title, 'Shopping');
    });

    testWidgets('says where to write when there is nothing in it yet', (
      tester,
    ) async {
      final state = await pumpList(tester);
      await state.addBlock('list', 'Shopping');
      await tester.pumpAndSettle();

      expect(find.text('Write here…'), findsOneWidget);
    });
  });

  group('moving a section', () {
    test('carries its items and rewrites the flat order to match', () async {
      final state = newTestState(FakeLocalStore());
      await state.init();
      await state.createProject('List');
      await state.addItem('list', 'Loose');
      await state.addBlock('list', 'First');
      await state.addItem('list', 'One', block: 'First');
      await state.addBlock('list', 'Second');
      await state.addItem('list', 'Two', block: 'Second');

      await state.reorderBlocks('list', 1, 0);

      expect(state.projects.single.blocks.map((b) => b.title), [
        'Second',
        'First',
      ]);
      // The ungrouped item stays on top, and each section's items follow it in
      // the new order.
      expect(state.projects.single.items.map((i) => i.text), [
        'Loose',
        'Two',
        'One',
      ]);
    });

    test('moving down accounts for the gap the row leaves behind', () async {
      final state = newTestState(FakeLocalStore());
      await state.init();
      await state.createProject('List');
      for (final name in ['A', 'B', 'C']) {
        await state.addBlock('list', name);
      }

      await state.reorderBlocks('list', 0, 3);
      expect(state.projects.single.blocks.map((b) => b.title), ['B', 'C', 'A']);
    });

    test('a move that changes nothing leaves the project alone', () async {
      final state = newTestState(FakeLocalStore());
      await state.init();
      await state.createProject('List');
      await state.addBlock('list', 'A');
      await state.addBlock('list', 'B');

      await state.reorderBlocks('list', 0, 1);
      expect(state.projects.single.blocks.map((b) => b.title), ['A', 'B']);
    });
  });
}
