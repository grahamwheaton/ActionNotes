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
    testWidgets('is a box you drag out, and it is the size you dragged', (
      tester,
    ) async {
      final state = await pumpBoard(tester);

      await tester.tap(find.byTooltip('Frame'));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(500, 300), const Offset(240, 160));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Ideas');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      // The name is a bullet like any other card, so a canvas read anywhere
      // else still says what its groups were called.
      expect(state.projects.single.blocks.single.body, contains('- Ideas'));

      final frame = spotsOf(state).last;
      expect(frame.isFrame, isTrue);
      // The size is what was dragged, not a guess: that is the point of
      // drawing a frame rather than asking for one.
      expect(frame.width, closeTo(240, 1));
      expect(frame.height, closeTo(160, 1));
      // And it starts at the corner the drag started from, rather than
      // eighteen pixels along it.
      expect(frame.x, closeTo(500, 1));
      // Behind everything, because a frame is what the cards stand on.
      expect(frame.z, lessThan(spotsOf(state).first.z));
      await settle(tester);
    });

    testWidgets('a press that goes nowhere makes no frame', (tester) async {
      final state = await pumpBoard(tester);
      final before = spotsOf(state).length;

      await tester.tap(find.byTooltip('Frame'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(500, 300));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsNothing);
      expect(spotsOf(state).length, before);
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

  group('a sticky note on something', () {
    testWidgets('travels with what it is sitting on', (tester) async {
      final state = await pumpBoard(
        tester,
        body: '- One\n- A note',
        spots: const [
          CanvasSpot(x: 100, y: 100, width: 400, ref: 'One'),
          // Sitting on top of it: both are short cards, so the note has to
          // start at much the same height to be standing on the other.
          CanvasSpot(
            x: 200,
            y: 102,
            width: 120,
            ref: 'A note',
            kind: CanvasSpotKind.sticky,
            colour: CanvasColour.yellow,
          ),
        ],
      );

      await tester.drag(
        find.descendant(
          of: find.byType(CanvasScreen),
          matching: find.text('One'),
        ),
        const Offset(90, 70),
      );
      await tester.pumpAndSettle();

      final spots = spotsOf(state);
      expect(spots[0].x, 190);
      // A note put on a photograph is about that photograph, so it comes
      // along rather than being left behind on the board.
      expect(spots[1].x, 290);
      expect(spots[1].y, 172);
      await settle(tester);
    });

    testWidgets('a note beside it, not on it, stays where it is', (
      tester,
    ) async {
      final state = await pumpBoard(
        tester,
        body: '- One\n- A note',
        spots: const [
          CanvasSpot(x: 100, y: 100, width: 200, ref: 'One'),
          CanvasSpot(
            x: 700,
            y: 700,
            width: 120,
            ref: 'A note',
            kind: CanvasSpotKind.sticky,
          ),
        ],
      );

      await tester.drag(
        find.descendant(
          of: find.byType(CanvasScreen),
          matching: find.text('One'),
        ),
        const Offset(50, 50),
      );
      await tester.pumpAndSettle();

      expect(spotsOf(state)[1].x, 700);
      await settle(tester);
    });
  });

  group('a frame is taken hold of by its name', () {
    testWidgets('dragging its middle leaves it where it is', (tester) async {
      final state = await pumpBoard(
        tester,
        body: '- Ideas',
        spots: const [
          CanvasSpot(
            x: 0,
            y: 0,
            width: 500,
            height: 400,
            ref: 'Ideas',
            kind: CanvasSpotKind.frame,
          ),
        ],
      );

      // Well inside the frame, away from its name.
      await tester.dragFrom(const Offset(400, 400), const Offset(80, 80));
      await tester.pumpAndSettle();

      // The body is the space things stand in: a press there belongs to the
      // canvas, so that a pinch can zoom and a marquee can select.
      expect(spotsOf(state).single.x, 0);
      await settle(tester);
    });

    testWidgets('dragging its name moves it', (tester) async {
      final state = await pumpBoard(
        tester,
        body: '- Ideas',
        spots: const [
          CanvasSpot(
            x: 0,
            y: 0,
            width: 500,
            height: 400,
            ref: 'Ideas',
            kind: CanvasSpotKind.frame,
          ),
        ],
      );

      await tester.drag(
        find.descendant(
          of: find.byType(CanvasScreen),
          matching: find.text('Ideas'),
        ),
        const Offset(70, 40),
      );
      await tester.pumpAndSettle();

      expect(spotsOf(state).single.x, 70);
      expect(spotsOf(state).single.y, 40);
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

    testWidgets('a note can be dropped straight onto a picture', (
      tester,
    ) async {
      final state = await pumpBoard(
        tester,
        body: '- One',
        spots: const [CanvasSpot(x: 200, y: 150, width: 400, ref: 'One')],
      );

      await tester.tap(find.byTooltip('Text'));
      await tester.pumpAndSettle();

      // On top of the card. With a tool in hand the press is the tool's, not
      // the card's — otherwise it looked as though the tool only worked once
      // something else had been selected.
      final card = tester.getRect(
        find.descendant(
          of: find.byType(CanvasScreen),
          matching: find.text('One'),
        ),
      );
      await tester.tapAt(card.center);
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'A caption');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(spotsOf(state).last.kind, CanvasSpotKind.text);
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

    testWidgets('the pen draws at the weight that was chosen', (tester) async {
      final state = await pumpBoard(tester);

      await tester.tap(find.byTooltip('Pen'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Bold'));
      await tester.pumpAndSettle();

      await tester.dragFrom(const Offset(600, 400), const Offset(60, 60));
      await tester.pumpAndSettle();

      expect(state.canvasDrawing('list', 'Board').single.thickness, 5);
      await settle(tester);
    });

    testWidgets('an arrow ending on a card holds on to it, and follows it', (
      tester,
    ) async {
      final state = await pumpBoard(
        tester,
        body: '- One\n- Two',
        spots: const [
          CanvasSpot(x: 400, y: 300, width: 120, ref: 'One'),
          CanvasSpot(x: 900, y: 900, width: 120, ref: 'Two'),
        ],
      );

      await tester.tap(find.byTooltip('Shapes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Arrow').last);
      await tester.pumpAndSettle();

      // From empty canvas into the card, so only the far end takes hold.
      final card = tester.getRect(
        find.descendant(
          of: find.byType(CanvasScreen),
          matching: find.text('One'),
        ),
      );
      await tester.dragFrom(
        const Offset(200, 600),
        card.center - const Offset(200, 600),
      );
      await tester.pumpAndSettle();

      final arrow = state.canvasDrawing('list', 'Board').single;
      expect(arrow.kind, CanvasShapeKind.arrow);
      expect(arrow.from, isNull);
      expect(arrow.to?.ref, 'One');

      // Renaming the card it holds carries the hold, rather than letting go.
      await state.setCanvasCard('list', 'Board', 0, 'Won');
      await tester.pumpAndSettle();
      expect(state.canvasDrawing('list', 'Board').single.to?.ref, 'Won');
      await settle(tester);
    });

    testWidgets('an arrow can be drawn straight across a card', (tester) async {
      final state = await pumpBoard(
        tester,
        body: '- One',
        spots: const [CanvasSpot(x: 300, y: 200, width: 400, ref: 'One')],
      );

      await tester.tap(find.byTooltip('Shapes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Arrow').last);
      await tester.pumpAndSettle();

      // Starting on top of the card: with a tool in hand the press is a mark
      // being drawn, not the card being picked up.
      final card = tester.getRect(
        find.descendant(
          of: find.byType(CanvasScreen),
          matching: find.text('One'),
        ),
      );
      await tester.dragFrom(card.center, const Offset(200, 150));
      await tester.pumpAndSettle();

      expect(state.canvasDrawing('list', 'Board'), hasLength(1));
      // And nothing was selected by the press that started it.
      expect(find.text('1 selected'), findsNothing);
      await settle(tester);
    });

    testWidgets('a line ending on a card does not hold on to it', (
      tester,
    ) async {
      final state = await pumpBoard(
        tester,
        body: '- One',
        spots: const [CanvasSpot(x: 400, y: 300, width: 120, ref: 'One')],
      );

      await tester.tap(find.byTooltip('Shapes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Line').last);
      await tester.pumpAndSettle();

      final card = tester.getRect(
        find.descendant(
          of: find.byType(CanvasScreen),
          matching: find.text('One'),
        ),
      );
      await tester.dragFrom(
        const Offset(200, 600),
        card.center - const Offset(200, 600),
      );
      await tester.pumpAndSettle();

      // A line is a line on the board; only an arrow points at something.
      expect(state.canvasDrawing('list', 'Board').single.isStuck, isFalse);
      await settle(tester);
    });

    testWidgets('an arrow can be given a node, bent, and rubbed out from '
        'its own menu', (tester) async {
      final state = await pumpBoard(tester);

      await tester.tap(find.byTooltip('Shapes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Arrow').last);
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(400, 600), const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(state.canvasDrawing('list', 'Board'), hasLength(1));

      // A mark has no box of its own, so the press lands on the canvas and
      // the mark under it is looked for.
      await tester.longPressAt(const Offset(550, 600));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add a node here'));
      await tester.pumpAndSettle();

      final withNode = state.canvasDrawing('list', 'Board').single;
      expect(withNode.points, hasLength(6));

      await tester.longPressAt(const Offset(500, 600));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Make it bendy'));
      await tester.pumpAndSettle();

      expect(state.canvasDrawing('list', 'Board').single.curved, isTrue);

      await tester.longPressAt(const Offset(500, 600));
      await tester.pumpAndSettle();
      // And it says so, so the same entry takes it back.
      expect(find.text('Make it straight'), findsOneWidget);
      await tester.tap(find.text('Rub it out'));
      await tester.pumpAndSettle();

      expect(state.canvasDrawing('list', 'Board'), isEmpty);
      await settle(tester);
    });

    testWidgets('a node can be dragged, and the end it moves lets go of its '
        'card', (tester) async {
      final state = await pumpBoard(
        tester,
        body: '- One',
        spots: const [CanvasSpot(x: 300, y: 200, width: 200, ref: 'One')],
      );

      await tester.tap(find.byTooltip('Shapes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Arrow').last);
      await tester.pumpAndSettle();

      final card = tester.getRect(
        find.descendant(
          of: find.byType(CanvasScreen),
          matching: find.text('One'),
        ),
      );
      await tester.dragFrom(
        const Offset(300, 700),
        card.center - const Offset(300, 700),
      );
      await tester.pumpAndSettle();
      expect(state.canvasDrawing('list', 'Board').single.to, isNotNull);

      // Pick the mark, which is what puts its nodes on show.
      await tester.longPressAt(const Offset(300, 700));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Make it bendy'));
      await tester.pumpAndSettle();

      final handles = find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_NodeHandle',
      );
      expect(handles, findsNWidgets(2));

      await tester.drag(handles.last, const Offset(0, 120));
      await tester.pumpAndSettle();

      // Dragged by hand is where it was put, so the hold is given up rather
      // than snapping the node back to the card.
      expect(state.canvasDrawing('list', 'Board').single.to, isNull);
      await settle(tester);
    });

    testWidgets('an arrow inside a frame holds the card, not the frame', (
      tester,
    ) async {
      final state = await pumpBoard(
        tester,
        body: '- Ideas\n- One',
        spots: const [
          CanvasSpot(
            x: 0,
            y: 0,
            width: 600,
            height: 500,
            z: -1,
            ref: 'Ideas',
            kind: CanvasSpotKind.frame,
          ),
          CanvasSpot(x: 200, y: 200, width: 150, ref: 'One'),
        ],
      );

      await tester.tap(find.byTooltip('Shapes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Arrow').last);
      await tester.pumpAndSettle();

      final card = tester.getRect(
        find.descendant(
          of: find.byType(CanvasScreen),
          matching: find.text('One'),
        ),
      );
      await tester.dragFrom(
        const Offset(700, 650),
        card.center - const Offset(700, 650),
      );
      await tester.pumpAndSettle();

      // The card it was dropped on, not the room it is standing in.
      expect(state.canvasDrawing('list', 'Board').single.to?.ref, 'One');
      await settle(tester);
    });

    testWidgets('a mark drawn inside a frame travels with it', (tester) async {
      final state = await pumpBoard(
        tester,
        body: '- Ideas',
        spots: const [
          CanvasSpot(
            x: 0,
            y: 0,
            width: 600,
            height: 500,
            ref: 'Ideas',
            kind: CanvasSpotKind.frame,
          ),
        ],
      );

      await tester.tap(find.byTooltip('Pen'));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(200, 300), const Offset(80, 40));
      await tester.pumpAndSettle();

      final before = state.canvasDrawing('list', 'Board').single.points;
      expect(before, isNotEmpty);

      // The pen stays armed, so put it down before dragging anything.
      await tester.tap(find.byTooltip('Select'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.descendant(
          of: find.byType(CanvasScreen),
          matching: find.text('Ideas'),
        ),
        const Offset(120, 60),
      );
      await tester.pumpAndSettle();

      final after = state.canvasDrawing('list', 'Board').single.points;
      // Every point moved by exactly what the frame moved: a pen note beside
      // a photograph is about that photograph, so leaving it behind would
      // pull the two apart.
      for (var i = 0; i < before.length; i++) {
        expect(after[i], closeTo(before[i] + (i.isEven ? 120 : 60), 1));
      }
      await settle(tester);
    });

    testWidgets('a mark that only crosses a frame is left where it is', (
      tester,
    ) async {
      final state = await pumpBoard(
        tester,
        body: '- Ideas',
        spots: const [
          CanvasSpot(
            x: 0,
            y: 0,
            width: 300,
            height: 200,
            ref: 'Ideas',
            kind: CanvasSpotKind.frame,
          ),
        ],
      );

      await tester.tap(find.byTooltip('Pen'));
      await tester.pumpAndSettle();
      // Starts inside the frame and runs well past its edge.
      await tester.dragFrom(const Offset(200, 250), const Offset(600, 0));
      await tester.pumpAndSettle();

      final before = state.canvasDrawing('list', 'Board').single.points;

      await tester.tap(find.byTooltip('Select'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.descendant(
          of: find.byType(CanvasScreen),
          matching: find.text('Ideas'),
        ),
        const Offset(100, 50),
      );
      await tester.pumpAndSettle();

      expect(state.canvasDrawing('list', 'Board').single.points, before);
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
