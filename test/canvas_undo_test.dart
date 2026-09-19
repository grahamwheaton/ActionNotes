import 'package:actionnotes/models/canvas_layout.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/canvas_screen.dart';
import 'package:actionnotes/ui/checklist_view.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:actionnotes/ui/touch_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

const three = [
  CanvasSpot(x: 100, y: 100, width: 120, ref: 'One'),
  CanvasSpot(x: 500, y: 400, width: 200, ref: 'Two'),
  CanvasSpot(x: 900, y: 700, width: 120, ref: 'Three'),
];

Future<AppState> pumpCanvas(WidgetTester tester) async {
  TouchInput.debugOverride = false;
  addTearDown(() => TouchInput.debugOverride = null);

  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final state = newTestState(FakeLocalStore());
  await state.init();
  await state.createProject('List');
  await state.addBlock('list', 'Board');
  await state.setBlockBody('list', 'Board', '- One\n- Two\n- Three');
  await state.setCanvas('list', 'Board', true);
  await state.setCanvasSpots('list', 'Board', three);

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
  await tester.tap(find.byTooltip('Open full screen'));
  await tester.pumpAndSettle();
  return state;
}

Finder onCanvas(String text) =>
    find.descendant(of: find.byType(CanvasScreen), matching: find.text(text));

Future<void> settle(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
}

List<CanvasSpot> spotsOf(AppState state) =>
    state.layoutFor('list').spotsFor('Board');

void main() {
  group('taking a canvas change back', () {
    test('there is nothing to undo on a canvas nobody has touched', () async {
      final state = newTestState(FakeLocalStore());
      await state.init();
      await state.createProject('List');
      await state.addBlock('list', 'Board');
      await state.setCanvas('list', 'Board', true);

      expect(state.canUndoCanvas('list', 'Board'), isFalse);
      expect(state.canRedoCanvas('list', 'Board'), isFalse);
    });

    testWidgets('a move can be put back', (tester) async {
      final state = await pumpCanvas(tester);

      await tester.drag(onCanvas('One'), const Offset(150, 120));
      await tester.pumpAndSettle();
      expect(spotsOf(state)[0].x, greaterThan(200));

      await tester.tap(find.byTooltip('Undo'));
      await tester.pumpAndSettle();

      expect(spotsOf(state)[0].x, 100);
      expect(spotsOf(state)[0].y, 100);
      await settle(tester);
    });

    testWidgets('and put back again with redo', (tester) async {
      final state = await pumpCanvas(tester);

      await tester.drag(onCanvas('One'), const Offset(150, 0));
      await tester.pumpAndSettle();
      final moved = spotsOf(state)[0].x;

      await tester.tap(find.byTooltip('Undo'));
      await tester.pumpAndSettle();
      expect(spotsOf(state)[0].x, 100);

      await tester.tap(find.byTooltip('Redo'));
      await tester.pumpAndSettle();
      expect(spotsOf(state)[0].x, closeTo(moved, 0.01));
      await settle(tester);
    });

    testWidgets('a deleted card comes back, markdown and all', (tester) async {
      final state = await pumpCanvas(tester);

      await tester.longPress(onCanvas('Two'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete card'));
      await tester.pumpAndSettle();
      expect(state.projects.single.blocks.single.body, '- One\n- Three');

      await tester.tap(find.byTooltip('Undo'));
      await tester.pumpAndSettle();

      expect(state.projects.single.blocks.single.body, '- One\n- Two\n- Three');
      // And its position with it, not a card in a default spot.
      expect(spotsOf(state)[1].x, 500);
      await settle(tester);
    });

    testWidgets('packing a board can be taken back in one go', (tester) async {
      final state = await pumpCanvas(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      await tester.longPress(onCanvas('One'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Line 3 up…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pack into rows'));
      await tester.pumpAndSettle();
      expect(spotsOf(state)[2].x, isNot(900));

      await tester.tap(find.byTooltip('Undo'));
      await tester.pumpAndSettle();

      expect(spotsOf(state).map((s) => s.x), [100, 500, 900]);
      await settle(tester);
    });

    testWidgets('Ctrl+Z undoes rather than zooming', (tester) async {
      final state = await pumpCanvas(tester);

      await tester.drag(onCanvas('One'), const Offset(150, 0));
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(spotsOf(state)[0].x, 100);
      await settle(tester);
    });

    testWidgets('a new change forgets what was undone', (tester) async {
      final state = await pumpCanvas(tester);

      await tester.drag(onCanvas('One'), const Offset(150, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Undo'));
      await tester.pumpAndSettle();
      expect(state.canRedoCanvas('list', 'Board'), isTrue);

      await tester.drag(onCanvas('Three'), const Offset(-120, 0));
      await tester.pumpAndSettle();

      expect(state.canRedoCanvas('list', 'Board'), isFalse);
      await settle(tester);
    });

    testWidgets('the buttons are dead until something has been done', (
      tester,
    ) async {
      // Its own setup: the shared one arranges the cards, which is itself a
      // change and would leave something to undo.
      TouchInput.debugOverride = false;
      addTearDown(() => TouchInput.debugOverride = null);
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final state = newTestState(FakeLocalStore());
      await state.init();
      await state.createProject('List');
      await state.addBlock('list', 'Board');
      await state.setBlockBody('list', 'Board', '- One\n- Two');
      await state.setCanvas('list', 'Board', true);

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
      await tester.tap(find.byTooltip('Open full screen'));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byTooltip('Undo'),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byTooltip('Redo'),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
      await settle(tester);
    });
  });
}
