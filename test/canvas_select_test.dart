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

/// A canvas on its own screen with three cards, spread out so a marquee can
/// catch some and not others.
Future<AppState> pumpCanvas(WidgetTester tester) async {
  TouchInput.debugOverride = false;
  addTearDown(() => TouchInput.debugOverride = null);

  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final state = newTestState(FakeLocalStore());
  await state.init();
  await state.createProject('List');
  await state.addBlock('list', 'Board');
  await state.setBlockBody('list', 'Board', '- One\n- Two\n- Three');
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
  return state;
}

Finder onCanvas(String text) =>
    find.descendant(of: find.byType(CanvasScreen), matching: find.text(text));

/// Lets the layout's two-second settle fire, so no timer outlives the test.
Future<void> settle(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
}

void main() {
  group('picking several cards', () {
    testWidgets('a plain click takes one and drops the rest', (tester) async {
      await pumpCanvas(tester);

      await tester.tap(onCanvas('One'));
      await tester.pumpAndSettle();
      await tester.tap(onCanvas('Two'));
      await tester.pumpAndSettle();

      // One selected, so no count is shown.
      expect(find.textContaining('selected'), findsNothing);
      await settle(tester);
    });

    testWidgets('ctrl-click adds to the selection, and says how many', (
      tester,
    ) async {
      await pumpCanvas(tester);

      await tester.tap(onCanvas('One'));
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(onCanvas('Two'));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      expect(find.text('2 selected'), findsOneWidget);
      await settle(tester);
    });

    testWidgets('ctrl-clicking a selected card takes it back out', (
      tester,
    ) async {
      await pumpCanvas(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(onCanvas('One'));
      await tester.pumpAndSettle();
      await tester.tap(onCanvas('Two'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);

      await tester.tap(onCanvas('Two'));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      expect(find.textContaining('selected'), findsNothing);
      await settle(tester);
    });

    testWidgets('ctrl+A takes the lot', (tester) async {
      await pumpCanvas(tester);

      await tester.tap(onCanvas('One'));
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(find.text('3 selected'), findsOneWidget);
      await settle(tester);
    });

    testWidgets('escape lets them all go', (tester) async {
      await pumpCanvas(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(onCanvas('One'));
      await tester.pumpAndSettle();
      await tester.tap(onCanvas('Two'));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(find.text('2 selected'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.textContaining('selected'), findsNothing);
      await settle(tester);
    });
  });

  group('doing something to several at once', () {
    testWidgets('dragging one of a group moves the group', (tester) async {
      final state = await pumpCanvas(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(onCanvas('One'));
      await tester.pumpAndSettle();
      await tester.tap(onCanvas('Two'));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      await tester.drag(onCanvas('One'), const Offset(70, 50));
      await tester.pumpAndSettle();

      final spots = state.layoutFor('list').spotsFor('Board');
      // Both moved by the same amount; the third did not move at all.
      expect(spots[0].x, closeTo(40 + 70, 1));
      expect(spots[1].x, closeTo(340 + 70, 1));
      expect(spots[2].x, closeTo(640, 1));
      await settle(tester);
    });

    testWidgets('the arrow keys nudge everything selected', (tester) async {
      final state = await pumpCanvas(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(onCanvas('One'));
      await tester.pumpAndSettle();
      await tester.tap(onCanvas('Two'));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      final spots = state.layoutFor('list').spotsFor('Board');
      expect(spots[0].x, closeTo(41, 0.01));
      expect(spots[1].x, closeTo(341, 0.01));
      expect(spots[2].x, closeTo(640, 0.01));
      await settle(tester);
    });

    testWidgets('the menu names how many it will act on', (tester) async {
      await pumpCanvas(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(onCanvas('One'));
      await tester.pumpAndSettle();
      await tester.tap(onCanvas('Two'));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      await tester.longPress(onCanvas('One'));
      await tester.pumpAndSettle();

      expect(find.text('Delete 2 cards'), findsOneWidget);
      expect(find.text('Bring 2 to front'), findsOneWidget);
      await settle(tester);
    });

    testWidgets('deleting several removes the right ones', (tester) async {
      final state = await pumpCanvas(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(onCanvas('One'));
      await tester.pumpAndSettle();
      await tester.tap(onCanvas('Two'));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      await tester.longPress(onCanvas('One'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete 2 cards'));
      await tester.pumpAndSettle();

      // The one that was not selected is the one that is left — taking them
      // in index order would have deleted the wrong cards.
      expect(state.projects.single.blocks.single.body, '- Three');
      await settle(tester);
    });

    testWidgets('a menu on a card outside the selection acts on that card', (
      tester,
    ) async {
      final state = await pumpCanvas(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(onCanvas('One'));
      await tester.pumpAndSettle();
      await tester.tap(onCanvas('Two'));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      await tester.longPress(onCanvas('Three'));
      await tester.pumpAndSettle();
      expect(find.text('Delete card'), findsOneWidget);
      await tester.tap(find.text('Delete card'));
      await tester.pumpAndSettle();

      expect(state.projects.single.blocks.single.body, '- One\n- Two');
      await settle(tester);
    });
  });

  group('the marquee', () {
    testWidgets('drags out a box and picks up what it touches', (tester) async {
      await pumpCanvas(tester);

      // The cards are laid out across the top in a row, so a box along it
      // catches the first two and stops short of the third.
      final one = tester.getRect(onCanvas('One'));
      final two = tester.getRect(onCanvas('Two'));

      await tester.dragFrom(
        Offset(one.left - 20, one.top - 20),
        Offset(two.right - one.left + 40, two.bottom - one.top + 40),
      );
      await tester.pumpAndSettle();

      expect(find.text('2 selected'), findsOneWidget);
      await settle(tester);
    });

    testWidgets('a tap on empty space lets everything go', (tester) async {
      await pumpCanvas(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(onCanvas('One'));
      await tester.pumpAndSettle();
      await tester.tap(onCanvas('Two'));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      await tester.tapAt(const Offset(500, 700));
      await tester.pumpAndSettle();

      expect(find.textContaining('selected'), findsNothing);
      await settle(tester);
    });
  });
}
