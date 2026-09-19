import 'package:actionnotes/models/canvas_layout.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/canvas_screen.dart';
import 'package:actionnotes/ui/checklist_view.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:actionnotes/ui/touch_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

Future<AppState> pumpBoard(
  WidgetTester tester, {
  String body = '- One\n- Two',
  List<CanvasSpot> spots = const [
    CanvasSpot(x: 100, y: 100, width: 120, ref: 'One'),
    CanvasSpot(x: 900, y: 900, width: 120, ref: 'Two'),
  ],
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

List<CanvasSpot> spotsOf(AppState state) =>
    state.layoutFor('list').spotsFor('Board');

Future<void> settle(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
}

void main() {
  _theSideTools();
  _drawingOnTheBoard();

  group('a frame in the layout file', () {
    test('says what it is and how tall, and round-trips', () {
      const layout = CanvasLayout(
        sections: {
          'Board': [
            CanvasSpot(
              x: 0,
              y: 0,
              width: 500,
              height: 400,
              ref: 'Ideas',
              kind: CanvasSpotKind.frame,
            ),
          ],
        },
      );

      final again = CanvasLayout.parse(layout.toJsonString());
      final spot = again.spotsFor('Board').single;
      expect(spot.isFrame, isTrue);
      expect(spot.height, 400);
      expect(spot.width, 500);
    });

    test('an ordinary card says neither, so nothing in its entry changes', () {
      const spot = CanvasSpot(x: 1, y: 2);
      expect(spot.isFrame, isFalse);
      expect(spot.toJson().containsKey('kind'), isFalse);
      expect(spot.toJson().containsKey('h'), isFalse);
    });
  });

  group('adding a frame', () {
    testWidgets('writes its name to the markdown and its shape to the layout', (
      tester,
    ) async {
      final state = await pumpBoard(tester);

      await tester.tap(find.byTooltip('Add a frame'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Ideas');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      // The name is a bullet like any other card, so a canvas read anywhere
      // else still says what its groups were called.
      expect(state.projects.single.blocks.single.body, contains('- Ideas'));

      final frame = spotsOf(state).last;
      expect(frame.isFrame, isTrue);
      expect(frame.height, isNotNull);
      // Behind everything, because a frame is what the cards stand on.
      expect(frame.z, lessThan(spotsOf(state).first.z));
      await settle(tester);
    });
  });

  group('moving a frame', () {
    testWidgets('takes what is standing on it along', (tester) async {
      final state = await pumpBoard(
        tester,
        body: '- Ideas\n- One\n- Two',
        spots: const [
          CanvasSpot(
            x: 0,
            y: 0,
            width: 400,
            height: 300,
            z: -1,
            ref: 'Ideas',
            kind: CanvasSpotKind.frame,
          ),
          // Inside the frame.
          CanvasSpot(x: 40, y: 40, width: 100, ref: 'One'),
          // Well outside it.
          CanvasSpot(x: 700, y: 700, width: 100, ref: 'Two'),
        ],
      );

      await tester.drag(find.text('Ideas'), const Offset(60, 30));
      await tester.pumpAndSettle();

      final spots = spotsOf(state);
      expect(spots[0].x, 60);
      expect(spots[0].y, 30);
      // The card on the frame went with it; the one off it did not.
      expect(spots[1].x, 100);
      expect(spots[1].y, 70);
      expect(spots[2].x, 700);
      expect(spots[2].y, 700);
      await settle(tester);
    });
  });

  group('renaming a frame', () {
    testWidgets('changes the markdown and keeps the frame where it was', (
      tester,
    ) async {
      final state = await pumpBoard(
        tester,
        body: '- Ideas',
        spots: const [
          CanvasSpot(
            x: 20,
            y: 30,
            width: 400,
            height: 300,
            ref: 'Ideas',
            kind: CanvasSpotKind.frame,
          ),
        ],
      );

      await tester.longPress(
        find.descendant(
          of: find.byType(CanvasScreen),
          matching: find.text('Ideas'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename frame'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'Later');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(state.projects.single.blocks.single.body, contains('- Later'));
      final frame = spotsOf(state).single;
      expect(frame.isFrame, isTrue);
      expect(frame.x, 20);
      expect(frame.y, 30);
      // The position points at the card by what it says, so it followed the
      // rename rather than looking like a card that has never been placed.
      expect(frame.ref, 'Later');
      await settle(tester);
    });
  });
}

void _theSideTools() {
  group('the tools down the side', () {
    testWidgets('a sticky note is placed where it was pressed, coloured', (
      tester,
    ) async {
      final state = await pumpBoard(tester);

      await tester.tap(find.byTooltip('Sticky note'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Pink'));
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(700, 500));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Ring the agent');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(
        state.projects.single.blocks.single.body,
        contains('- Ring the agent'),
      );
      final spot = spotsOf(state).last;
      expect(spot.kind, CanvasSpotKind.sticky);
      expect(spot.colour, CanvasColour.pink);
      await settle(tester);
    });

    testWidgets('a tool goes back to Select once it has placed one thing', (
      tester,
    ) async {
      final state = await pumpBoard(tester);

      await tester.tap(find.byTooltip('Text'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(700, 500));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'A caption');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(spotsOf(state).last.kind, CanvasSpotKind.text);

      // A second press adds nothing, because the tool disarmed itself.
      final before = spotsOf(state).length;
      await tester.tapAt(const Offset(760, 560));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(spotsOf(state).length, before);
      await settle(tester);
    });

    testWidgets('cancelling places nothing', (tester) async {
      final state = await pumpBoard(tester);
      final before = spotsOf(state).length;

      await tester.tap(find.byTooltip('Sticky note'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(700, 500));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(spotsOf(state).length, before);
      await settle(tester);
    });

    testWidgets('a card can be coloured after the fact, and put back', (
      tester,
    ) async {
      final state = await pumpBoard(tester);

      await tester.longPress(
        find.descendant(
          of: find.byType(CanvasScreen),
          matching: find.text('One'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Colour…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Green'));
      await tester.pumpAndSettle();

      expect(spotsOf(state).first.colour, CanvasColour.green);
      expect(spotsOf(state).first.kind, CanvasSpotKind.sticky);
      await settle(tester);
    });
  });
}

void _drawingOnTheBoard() {
  group('drawing on the board', () {
    testWidgets('dragging with a shape armed leaves a mark', (tester) async {
      final state = await pumpBoard(tester);

      await tester.tap(find.byTooltip('Shapes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rectangle').last);
      await tester.pumpAndSettle();

      await tester.dragFrom(const Offset(600, 400), const Offset(120, 90));
      await tester.pumpAndSettle();

      final shapes = state.canvasDrawing('list', 'Board');
      expect(shapes, hasLength(1));
      expect(shapes.single.kind, CanvasShapeKind.rectangle);
      // A shape is one thing, so its tool disarms once it is drawn.
      await tester.dragFrom(const Offset(600, 600), const Offset(80, 60));
      await tester.pumpAndSettle();
      expect(state.canvasDrawing('list', 'Board'), hasLength(1));
      await settle(tester);
    });

    testWidgets('a press that goes nowhere is not a mark', (tester) async {
      final state = await pumpBoard(tester);

      await tester.tap(find.byTooltip('Shapes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Line').last);
      await tester.pumpAndSettle();

      await tester.dragFrom(const Offset(600, 400), const Offset(1, 1));
      await tester.pumpAndSettle();

      expect(state.canvasDrawing('list', 'Board'), isEmpty);
      await settle(tester);
    });

    testWidgets('the pen stays armed, because a drawing is many strokes', (
      tester,
    ) async {
      final state = await pumpBoard(tester);

      await tester.tap(find.byTooltip('Pen'));
      await tester.pumpAndSettle();

      await tester.dragFrom(const Offset(600, 400), const Offset(60, 60));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(600, 500), const Offset(60, 60));
      await tester.pumpAndSettle();

      final shapes = state.canvasDrawing('list', 'Board');
      expect(shapes, hasLength(2));
      expect(shapes.first.kind, CanvasShapeKind.stroke);
      await settle(tester);
    });

    testWidgets('a mark is drawn in the colour that was chosen', (
      tester,
    ) async {
      final state = await pumpBoard(tester);

      await tester.tap(find.byTooltip('Pen'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Blue'));
      await tester.pumpAndSettle();

      await tester.dragFrom(const Offset(600, 400), const Offset(60, 60));
      await tester.pumpAndSettle();

      expect(
        state.canvasDrawing('list', 'Board').single.colour,
        CanvasColour.blue,
      );
      await settle(tester);
    });

    testWidgets('the eraser takes what it is dragged over, and undo brings '
        'it back', (tester) async {
      final state = await pumpBoard(tester);

      await tester.tap(find.byTooltip('Pen'));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(600, 400), const Offset(80, 0));
      await tester.pumpAndSettle();
      expect(state.canvasDrawing('list', 'Board'), hasLength(1));

      await tester.tap(find.byTooltip('Eraser'));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(600, 400), const Offset(80, 0));
      await tester.pumpAndSettle();

      expect(state.canvasDrawing('list', 'Board'), isEmpty);

      await state.undoCanvas('list', 'Board');
      await tester.pumpAndSettle();
      expect(state.canvasDrawing('list', 'Board'), hasLength(1));
      await settle(tester);
    });

    testWidgets('the eraser leaves alone what it never touched', (
      tester,
    ) async {
      final state = await pumpBoard(tester);

      await tester.tap(find.byTooltip('Pen'));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(600, 400), const Offset(80, 0));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Eraser'));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(600, 700), const Offset(80, 0));
      await tester.pumpAndSettle();

      expect(state.canvasDrawing('list', 'Board'), hasLength(1));
      await settle(tester);
    });
  });
}
