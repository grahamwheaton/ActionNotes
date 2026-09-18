import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/checklist_view.dart';
import 'package:actionnotes/ui/context_menu.dart';
import 'package:actionnotes/ui/note_blocks_editor.dart';
import 'package:actionnotes/ui/note_editor.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:actionnotes/ui/touch_input.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

/// A phone-sized window, so the editor takes a screen of its own rather than
/// the pane — which is what the gestures under test are for.
Future<AppState> pumpPhoneList(
  WidgetTester tester,
  List<String> items, {
  required bool touch,
}) async {
  TouchInput.debugOverride = touch;
  addTearDown(() => TouchInput.debugOverride = null);

  tester.view.physicalSize = const Size(420, 900);
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

/// Past the window in which a second tap would have made it a double tap.
Future<void> settleTap(WidgetTester tester) async {
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

void main() {
  _titleLayout();

  group('a row under a finger', () {
    testWidgets('one tap opens the notes in place, not the editor', (
      tester,
    ) async {
      await pumpPhoneList(tester, ['Buy milk'], touch: true);

      await tester.tap(find.text('Buy milk'));
      await settleTap(tester);

      expect(find.byType(NoteEditor), findsNothing);
      expect(find.byType(NoteBlocksEditor), findsOneWidget);
    });

    testWidgets('a double tap opens the editor and does not also expand', (
      tester,
    ) async {
      await pumpPhoneList(tester, ['Buy milk'], touch: true);

      final row = find.text('Buy milk');
      await tester.tap(row);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(row);
      await settleTap(tester);

      expect(find.byType(NoteEditor), findsOneWidget);
    });

    testWidgets('the actions are on a button, since long-press now moves', (
      tester,
    ) async {
      await pumpPhoneList(tester, ['Buy milk'], touch: true);

      expect(find.byType(ItemMenuButton), findsOneWidget);
      expect(find.byIcon(Icons.drag_indicator), findsNothing);

      await tester.tap(find.byType(ItemMenuButton));
      await tester.pumpAndSettle();

      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Move to...'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('a long press does not open the menu', (tester) async {
      await pumpPhoneList(tester, ['Buy milk'], touch: true);

      await tester.longPress(find.text('Buy milk'));
      await tester.pumpAndSettle();

      // Nothing from the menu: the hold belongs to the reorder now.
      expect(find.text('Rename'), findsNothing);
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('holding a row picks it up and moving it reorders the list', (
      tester,
    ) async {
      final state = await pumpPhoneList(tester, [
        'First',
        'Second',
      ], touch: true);
      expect(state.projects.single.items.map((i) => i.text), [
        'First',
        'Second',
      ]);

      final rowHeight = tester.getSize(find.byType(Checkbox).first).height + 40;

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('First')),
      );
      // Hold until the row is picked up, then carry it down past the other
      // one in steps, since the list moves rows as the pointer passes them.
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      for (var moved = 0.0; moved < rowHeight * 1.5; moved += 10) {
        await gesture.moveBy(const Offset(0, 10));
        await tester.pump(const Duration(milliseconds: 20));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(state.projects.single.items.map((i) => i.text), [
        'Second',
        'First',
      ]);
    });
  });

  group('a row under a mouse', () {
    testWidgets('one click still opens the editor', (tester) async {
      await pumpPhoneList(tester, ['Buy milk'], touch: false);

      await tester.tap(find.text('Buy milk'));
      await tester.pumpAndSettle();

      expect(find.byType(NoteEditor), findsOneWidget);
    });

    testWidgets('keeps its drag handle and its long-press menu', (
      tester,
    ) async {
      await pumpPhoneList(tester, ['Buy milk'], touch: false);

      expect(find.byIcon(Icons.drag_indicator), findsOneWidget);
      expect(find.byType(ItemMenuButton), findsNothing);

      await tester.longPress(find.text('Buy milk'));
      await tester.pumpAndSettle();

      expect(find.text('Rename'), findsOneWidget);
    });
  });

  group('the add bar', () {
    testWidgets('holding the button adds the item starred', (tester) async {
      final state = await pumpPhoneList(tester, [], touch: true);

      await tester.enterText(find.byType(TextField).last, 'Urgent');
      await tester.pumpAndSettle();

      await tester.longPress(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      final item = state.projects.single.items.single;
      expect(item.text, 'Urgent');
      expect(item.starred, isTrue);
    });

    testWidgets('tapping the button still adds it unstarred', (tester) async {
      final state = await pumpPhoneList(tester, [], touch: true);

      await tester.enterText(find.byType(TextField).last, 'Ordinary');
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      expect(state.projects.single.items.single.starred, isFalse);
    });

    testWidgets('the hint names the gesture the platform actually has', (
      tester,
    ) async {
      await pumpPhoneList(tester, [], touch: true);
      expect(find.text('Hold + to add it starred'), findsOneWidget);
      expect(find.text('Ctrl+Enter adds it starred'), findsNothing);
    });

    testWidgets('and names Ctrl+Enter where there is a keyboard', (
      tester,
    ) async {
      await pumpPhoneList(tester, [], touch: false);
      expect(find.text('Ctrl+Enter adds it starred'), findsOneWidget);
    });

    testWidgets('the button lines up with the text field it belongs to', (
      tester,
    ) async {
      await pumpPhoneList(tester, [], touch: true);

      final field = tester.getRect(find.byType(TextField).last);
      final button = tester.getRect(find.byIcon(Icons.add));

      // Within a couple of logical pixels, the two share a centre line. The
      // helper text used to hang below the field and drag the row's centre
      // down with it, leaving the button visibly low.
      expect(
        (field.center.dy - button.center.dy).abs(),
        lessThan(2.0),
        reason: 'field ${field.center.dy} vs button ${button.center.dy}',
      );
    });
  });
}

/// Opens a note editor on its own screen at [width], with a title long enough
/// that where it is laid out matters.
Future<void> pumpEditor(WidgetTester tester, double width) async {
  TouchInput.debugOverride = false;
  addTearDown(() => TouchInput.debugOverride = null);

  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  const title = 'Long task titles need to be full line display on mobile';

  final state = newTestState(FakeLocalStore());
  await state.init();
  await state.createProject('List');
  await addItemsInOrder(state, 'list', [title]);

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => NoteEditor.open(
                  context,
                  slug: 'list',
                  index: 0,
                  title: title,
                  initialNotes: '',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void _titleLayout() {
  const title = 'Long task titles need to be full line display on mobile';

  group("the note editor's title", () {
    testWidgets('on a phone it has the whole width, not the bar', (
      tester,
    ) async {
      await pumpEditor(tester, 420);

      final titleRect = tester.getRect(find.text(title));
      final screen = tester.getSize(find.byType(MaterialApp)).width;

      // Nearly the screen, rather than the column left over beside five
      // controls — which is what wrapped it onto five lines.
      expect(titleRect.width, greaterThan(screen * 0.85));

      // Below the bar, not inside it.
      final bar = tester.getRect(find.byType(AppBar));
      expect(titleRect.top, greaterThanOrEqualTo(bar.bottom));
    });

    testWidgets('a wider window keeps it in the bar beside the buttons', (
      tester,
    ) async {
      // Under the width at which the editor moves into the sidebar's pane,
      // so this is still a screen of its own — and over the one that puts the
      // title on a line of its own.
      await pumpEditor(tester, 700);

      final titleRect = tester.getRect(find.text(title));
      final bar = tester.getRect(find.byType(AppBar));
      expect(titleRect.top, lessThan(bar.bottom));
    });

    testWidgets('the star is still reachable from inside the note', (
      tester,
    ) async {
      await pumpEditor(tester, 420);
      expect(find.byTooltip('Star'), findsOneWidget);
    });
  });
}
