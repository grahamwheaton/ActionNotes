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

Future<AppState> pumpCanvas(
  WidgetTester tester, {
  required List<CanvasSpot> spots,
  String body = '- One\n- Two\n- Three',
}) async {
  TouchInput.debugOverride = false;
  addTearDown(() => TouchInput.debugOverride = null);

  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final state = newTestState(FakeLocalStore());
  await state.init();
  await state.createProject('List');
  await state.addBlock('list', 'Board');
  await state.setBlockBody('list', 'Board', body);
  await state.setCanvas('list', 'Board', true);
  await state.setCanvasSpots('list', 'Board', spots);

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
  group('lining up while dragging', () {
    testWidgets('a card dragged near another settles onto its edge', (
      tester,
    ) async {
      final state = await pumpCanvas(
        tester,
        spots: const [
          CanvasSpot(x: 100, y: 100, width: 120, ref: 'One'),
          CanvasSpot(x: 500, y: 400, width: 120, ref: 'Two'),
          CanvasSpot(x: 900, y: 700, width: 120, ref: 'Three'),
        ],
      );

      // Drag Two so its left edge lands five short of One's — within the
      // tolerance, so it should finish exactly on it.
      await tester.drag(onCanvas('Two'), const Offset(-395, 0));
      await tester.pumpAndSettle();

      expect(spotsOf(state)[1].x, 100);
      await settle(tester);
    });

    testWidgets('a card dragged well away from everything is left alone', (
      tester,
    ) async {
      final state = await pumpCanvas(
        tester,
        spots: const [
          CanvasSpot(x: 100, y: 100, width: 120, ref: 'One'),
          CanvasSpot(x: 500, y: 400, width: 120, ref: 'Two'),
          CanvasSpot(x: 900, y: 700, width: 120, ref: 'Three'),
        ],
      );

      await tester.drag(onCanvas('Two'), const Offset(-200, 0));
      await tester.pumpAndSettle();

      expect(spotsOf(state)[1].x, closeTo(300, 0.5));
      await settle(tester);
    });

    testWidgets('holding shift and alt drags past the line without snapping', (
      tester,
    ) async {
      final state = await pumpCanvas(
        tester,
        spots: const [
          CanvasSpot(x: 100, y: 100, width: 120, ref: 'One'),
          CanvasSpot(x: 500, y: 400, width: 120, ref: 'Two'),
          CanvasSpot(x: 900, y: 700, width: 120, ref: 'Three'),
        ],
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.drag(onCanvas('Two'), const Offset(-395, 0));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);

      expect(spotsOf(state)[1].x, closeTo(105, 0.5));
      await settle(tester);
    });

    testWidgets('alt drag copies a card and leaves the original in place', (
      tester,
    ) async {
      final state = await pumpCanvas(tester, spots: const [
        CanvasSpot(x: 100, y: 100, width: 120, ref: 'One'),
        CanvasSpot(x: 500, y: 400, width: 120, ref: 'Two'),
        CanvasSpot(x: 900, y: 700, width: 120, ref: 'Three'),
      ]);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.drag(onCanvas('Two'), const Offset(-200, 0));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);

      expect(spotsOf(state), hasLength(4));
      expect(spotsOf(state)[1].x, 500);
      expect(spotsOf(state).last.x, closeTo(300, 0.5));
      await settle(tester);
    });
  });

  group('lining up on demand', () {
    Future<void> selectTwo(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(onCanvas('One'));
      await tester.pumpAndSettle();
      await tester.tap(onCanvas('Two'));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }

    testWidgets('align left puts both on the leftmost edge', (tester) async {
      final state = await pumpCanvas(
        tester,
        spots: const [
          CanvasSpot(x: 100, y: 100, width: 120, ref: 'One'),
          CanvasSpot(x: 400, y: 400, width: 120, ref: 'Two'),
          CanvasSpot(x: 800, y: 700, width: 120, ref: 'Three'),
        ],
      );

      await selectTwo(tester);
      await tester.longPress(onCanvas('One'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Line 2 up…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Align left'));
      await tester.pumpAndSettle();

      expect(spotsOf(state)[0].x, 100);
      expect(spotsOf(state)[1].x, 100);
      // The one that was not selected stays where it was.
      expect(spotsOf(state)[2].x, 800);
      await settle(tester);
    });

    testWidgets('align right puts both on the rightmost edge', (tester) async {
      final state = await pumpCanvas(
        tester,
        spots: const [
          CanvasSpot(x: 100, y: 100, width: 120, ref: 'One'),
          CanvasSpot(x: 400, y: 400, width: 200, ref: 'Two'),
          CanvasSpot(x: 800, y: 700, width: 120, ref: 'Three'),
        ],
      );

      await selectTwo(tester);
      await tester.longPress(onCanvas('One'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Line 2 up…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Align right'));
      await tester.pumpAndSettle();

      // Right edges meet at 600: the wider card's own right edge.
      expect(spotsOf(state)[0].x + 120, closeTo(600, 0.01));
      expect(spotsOf(state)[1].x + 200, closeTo(600, 0.01));
      await settle(tester);
    });

    testWidgets('spreading is only offered once there are three', (
      tester,
    ) async {
      await pumpCanvas(
        tester,
        spots: const [
          CanvasSpot(x: 100, y: 100, width: 120, ref: 'One'),
          CanvasSpot(x: 400, y: 400, width: 120, ref: 'Two'),
          CanvasSpot(x: 800, y: 700, width: 120, ref: 'Three'),
        ],
      );

      await selectTwo(tester);
      await tester.longPress(onCanvas('One'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Line 2 up…'));
      await tester.pumpAndSettle();

      expect(find.text('Align left'), findsOneWidget);
      expect(find.text('Spread across'), findsNothing);
      await settle(tester);
    });

    testWidgets('spreading leaves the outermost two and evens the gaps', (
      tester,
    ) async {
      final state = await pumpCanvas(
        tester,
        spots: const [
          CanvasSpot(x: 0, y: 100, width: 100, ref: 'One'),
          CanvasSpot(x: 150, y: 100, width: 100, ref: 'Two'),
          CanvasSpot(x: 700, y: 100, width: 100, ref: 'Three'),
        ],
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      await tester.longPress(onCanvas('One'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Line 3 up…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Spread across'));
      await tester.pumpAndSettle();

      final spots = spotsOf(state);
      // The ends stay put and the middle one lands halfway between.
      expect(spots[0].x, 0);
      expect(spots[2].x, closeTo(700, 0.01));
      expect(spots[1].x, closeTo(350, 0.01));
      await settle(tester);
    });
  });
}
