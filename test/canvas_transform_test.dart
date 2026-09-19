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

Future<void> menuOn(WidgetTester tester, String card) async {
  await tester.longPress(onCanvas(card));
  await tester.pumpAndSettle();
}

const threeApart = [
  CanvasSpot(x: 100, y: 100, width: 120, ref: 'One'),
  CanvasSpot(x: 500, y: 400, width: 200, ref: 'Two'),
  CanvasSpot(x: 900, y: 700, width: 120, ref: 'Three'),
];

void main() {
  group('what the layout file carries', () {
    test('a plain card writes no transform at all', () {
      const spot = CanvasSpot(x: 1, y: 2);
      expect(spot.toJson().containsKey('r'), isFalse);
      expect(spot.toJson().containsKey('fx'), isFalse);
      expect(spot.toJson().containsKey('lock'), isFalse);
    });

    test('a turned, mirrored, locked card round-trips', () {
      const layout = CanvasLayout(
        sections: {
          'Board': [
            CanvasSpot(
              x: 1,
              y: 2,
              rotation: 37.5,
              flipX: true,
              flipY: true,
              locked: true,
              ref: 'a.png',
            ),
          ],
        },
      );
      final again = CanvasLayout.parse(
        layout.toJsonString(),
      ).spotsFor('Board').single;
      expect(again.rotation, 37.5);
      expect(again.flipX, isTrue);
      expect(again.flipY, isTrue);
      expect(again.locked, isTrue);
    });

    test('a file from before these existed reads as untouched', () {
      final spot = CanvasSpot.fromJson(const {'x': 1, 'y': 2, 'w': 100});
      expect(spot.rotation, 0);
      expect(spot.flipX, isFalse);
      expect(spot.locked, isFalse);
    });
  });

  group('flipping and straightening', () {
    testWidgets('flip across mirrors the card and says so in the file', (
      tester,
    ) async {
      final state = await pumpCanvas(tester, spots: threeApart);

      await menuOn(tester, 'One');
      await tester.tap(find.text('Flip across'));
      await tester.pumpAndSettle();

      expect(spotsOf(state)[0].flipX, isTrue);
      expect(spotsOf(state)[1].flipX, isFalse);
      await settle(tester);
    });

    testWidgets('straighten is only offered once something is turned', (
      tester,
    ) async {
      await pumpCanvas(tester, spots: threeApart);

      await menuOn(tester, 'One');
      expect(find.text('Straighten'), findsNothing);
      await tester.tapAt(const Offset(20, 860));
      await tester.pumpAndSettle();
      await settle(tester);
    });

    testWidgets('and it puts a turned card back', (tester) async {
      final state = await pumpCanvas(
        tester,
        spots: const [
          CanvasSpot(x: 100, y: 100, width: 120, rotation: 30, ref: 'One'),
          CanvasSpot(x: 500, y: 400, width: 200, ref: 'Two'),
          CanvasSpot(x: 900, y: 700, width: 120, ref: 'Three'),
        ],
      );

      await menuOn(tester, 'One');
      await tester.tap(find.text('Straighten'));
      await tester.pumpAndSettle();

      expect(spotsOf(state)[0].rotation, 0);
      await settle(tester);
    });
  });

  group('locking', () {
    testWidgets('a locked card cannot be dragged', (tester) async {
      final state = await pumpCanvas(tester, spots: threeApart);

      await menuOn(tester, 'One');
      await tester.tap(find.text('Lock in place'));
      await tester.pumpAndSettle();
      expect(spotsOf(state)[0].locked, isTrue);

      await tester.drag(onCanvas('One'), const Offset(200, 200));
      await tester.pumpAndSettle();

      expect(spotsOf(state)[0].x, 100);
      expect(spotsOf(state)[0].y, 100);
      await settle(tester);
    });

    testWidgets('and unlocking lets it move again', (tester) async {
      final state = await pumpCanvas(
        tester,
        spots: const [
          CanvasSpot(x: 100, y: 100, width: 120, locked: true, ref: 'One'),
          CanvasSpot(x: 500, y: 400, width: 200, ref: 'Two'),
          CanvasSpot(x: 900, y: 700, width: 120, ref: 'Three'),
        ],
      );

      await menuOn(tester, 'One');
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();

      await tester.drag(onCanvas('One'), const Offset(200, 0));
      await tester.pumpAndSettle();

      expect(spotsOf(state)[0].x, greaterThan(200));
      await settle(tester);
    });
  });

  group('duplicating', () {
    testWidgets('puts a second card in the markdown, beside the first', (
      tester,
    ) async {
      final state = await pumpCanvas(tester, spots: threeApart);

      await menuOn(tester, 'Two');
      await tester.tap(find.text('Duplicate'));
      await tester.pumpAndSettle();

      expect(
        state.projects.single.blocks.single.body,
        '- One\n- Two\n- Two\n- Three',
      );
      // The copy is offset, not exactly on top of the original.
      expect(spotsOf(state)[2].x, 524);
      await settle(tester);
    });
  });

  group('stacking one step at a time', () {
    testWidgets('forward one swaps with the card above it', (tester) async {
      final state = await pumpCanvas(
        tester,
        spots: const [
          CanvasSpot(x: 100, y: 100, width: 120, z: 0, ref: 'One'),
          CanvasSpot(x: 500, y: 400, width: 200, z: 1, ref: 'Two'),
          CanvasSpot(x: 900, y: 700, width: 120, z: 2, ref: 'Three'),
        ],
      );

      // Opening the menu on a card raises it, so One is on top to begin with.
      await menuOn(tester, 'One');
      await tester.tap(find.text('Back one'));
      await tester.pumpAndSettle();

      final spots = spotsOf(state);
      // One step down: exactly one card is above it now.
      final above = spots.where((s) => s.z > spots[0].z).length;
      expect(above, 1);
      await settle(tester);
    });
  });

  group('arranging', () {
    testWidgets('packing lays everything out in rows from where it was', (
      tester,
    ) async {
      final state = await pumpCanvas(
        tester,
        spots: const [
          CanvasSpot(x: 0, y: 0, width: 100, ref: 'One'),
          CanvasSpot(x: 800, y: 40, width: 100, ref: 'Two'),
          CanvasSpot(x: 400, y: 600, width: 100, ref: 'Three'),
        ],
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      await menuOn(tester, 'One');
      await tester.tap(find.text('Line 3 up…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pack into rows'));
      await tester.pumpAndSettle();

      final spots = spotsOf(state);
      // Everything starts at the old top-left corner and is packed together,
      // rather than left spread across hundreds of pixels.
      expect(spots.map((s) => s.x).reduce((a, b) => a < b ? a : b), 0);
      final spread = spots.map((s) => s.x).reduce((a, b) => a > b ? a : b);
      expect(spread, lessThan(400));
      await settle(tester);
    });

    testWidgets('matching the widest makes them all one width', (tester) async {
      final state = await pumpCanvas(tester, spots: threeApart);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      await menuOn(tester, 'One');
      await tester.tap(find.text('Line 3 up…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Match the widest'));
      await tester.pumpAndSettle();

      expect(spotsOf(state).map((s) => s.width), [200, 200, 200]);
      await settle(tester);
    });
  });
}
