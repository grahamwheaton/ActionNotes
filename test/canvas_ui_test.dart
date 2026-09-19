import 'package:actionnotes/markdown/canvas_cards.dart';
import 'package:actionnotes/models/canvas_layout.dart';
import 'package:actionnotes/ui/canvas_view.dart';
import 'package:actionnotes/ui/checklist_view.dart';
import 'package:actionnotes/ui/context_menu.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:actionnotes/ui/touch_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

/// The surface on its own, with cards that need no files behind them.
Future<List<CanvasSpot>> pumpCanvas(
  WidgetTester tester, {
  List<CanvasCard>? cards,
  List<CanvasSpot>? spots,
}) async {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final used = cards ?? [CanvasCards.text('First'), CanvasCards.text('Second')];
  final placed =
      spots ??
      const [
        CanvasSpot(x: 0, y: 0, width: 200, z: 0, ref: 'First'),
        CanvasSpot(x: 300, y: 0, width: 200, z: 1, ref: 'Second'),
      ];

  var latest = placed;
  final state = newTestState(FakeLocalStore());
  await state.init();

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: CanvasView(
            slug: 'list',
            section: 'Moodboard',
            cards: used,
            spots: placed,
            onChanged: (moved) => latest = moved,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return latest;
}

void main() {
  _addingToACanvas();

  group('moving a card', () {
    testWidgets('drags it, and reports where it ended up', (tester) async {
      List<CanvasSpot>? reported;

      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final state = newTestState(FakeLocalStore());
      await state.init();

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: CanvasView(
                slug: 'list',
                section: 'Moodboard',
                cards: [CanvasCards.text('First')],
                spots: const [CanvasSpot(x: 0, y: 0, width: 200, ref: 'First')],
                onChanged: (moved) => reported = moved,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.drag(find.text('First'), const Offset(60, 40));
      await tester.pumpAndSettle();

      expect(reported, isNotNull);
      expect(reported!.single.x, closeTo(60, 1));
      expect(reported!.single.y, closeTo(40, 1));
    });

    testWidgets('a card that is grabbed comes to the front', (tester) async {
      List<CanvasSpot>? reported;

      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final state = newTestState(FakeLocalStore());
      await state.init();

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: CanvasView(
                slug: 'list',
                section: 'Moodboard',
                cards: [CanvasCards.text('Back'), CanvasCards.text('Front')],
                spots: const [
                  CanvasSpot(x: 0, y: 0, width: 200, z: 0, ref: 'Back'),
                  CanvasSpot(x: 300, y: 0, width: 200, z: 5, ref: 'Front'),
                ],
                onChanged: (moved) => reported = moved,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Comfortably past the slop, or the drag is never recognised at all.
      await tester.drag(find.text('Back'), const Offset(40, 0));
      await tester.pumpAndSettle();

      expect(reported!.first.z, greaterThan(reported!.last.z));
    });
  });

  group('zooming', () {
    testWidgets('the readout starts at 100% and the buttons change it', (
      tester,
    ) async {
      await pumpCanvas(tester);
      expect(find.text('100%'), findsOneWidget);

      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pumpAndSettle();
      expect(find.text('100%'), findsNothing);

      // And the readout taps back to actual size.
      await tester.tap(find.text('120%'));
      await tester.pumpAndSettle();
      expect(find.text('100%'), findsOneWidget);
    });

    testWidgets('fit brings a far-flung card back into view', (tester) async {
      await pumpCanvas(
        tester,
        cards: [CanvasCards.text('Far')],
        spots: const [CanvasSpot(x: 4000, y: 4000, width: 200, ref: 'Far')],
      );

      await tester.tap(find.byTooltip('Fit all (F)'));
      await tester.pumpAndSettle();

      final card = tester.getRect(find.text('Far'));
      final view = tester.getRect(find.byType(CanvasView));
      expect(card.left, greaterThan(view.left - 1));
      expect(card.right, lessThan(view.right + 1));
    });
  });

  group('a canvas is a section, not a format', () {
    testWidgets('the menu turns one into a canvas and back', (tester) async {
      TouchInput.debugOverride = true;
      addTearDown(() => TouchInput.debugOverride = null);
      tester.view.physicalSize = const Size(600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final state = newTestState(FakeLocalStore());
      await state.init();
      await state.createProject('List');
      await state.addBlock('list', 'Moodboard');
      await state.setBlockBody('list', 'Moodboard', '- A note on the board');

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

      expect(find.byType(CanvasView), findsNothing);

      await tester.tap(find.byTooltip('Section actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Turn into a canvas'));
      await tester.pumpAndSettle();

      expect(find.byType(CanvasView), findsOneWidget);
      expect(state.isCanvas('list', 'Moodboard'), isTrue);
      // The markdown is untouched: a canvas is an arrangement of what was
      // already there.
      expect(state.projects.single.blocks.single.body, '- A note on the board');

      await tester.tap(find.byTooltip('Section actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show as notes'));
      await tester.pumpAndSettle();

      expect(find.byType(CanvasView), findsNothing);
      expect(state.projects.single.blocks.single.body, '- A note on the board');
    });

    testWidgets('renaming the section carries its canvas', (tester) async {
      final state = newTestState(FakeLocalStore());
      await state.init();
      await state.createProject('List');
      await state.addBlock('list', 'Moodboard');
      await state.setCanvas('list', 'Moodboard', true);

      await state.renameBlock('list', 'Moodboard', 'References');

      expect(state.isCanvas('list', 'Moodboard'), isFalse);
      expect(state.isCanvas('list', 'References'), isTrue);
    });

    testWidgets('positions are remembered on the device', (tester) async {
      final store = FakeLocalStore();
      final state = newTestState(store);
      await state.init();
      await state.createProject('List');
      await state.addBlock('list', 'Moodboard');
      await state.setCanvas('list', 'Moodboard', true);
      await state.setCanvasSpots('list', 'Moodboard', const [
        CanvasSpot(x: 12, y: 34, ref: 'a.png'),
      ]);
      await tester.pump(const Duration(seconds: 2));

      final reopened = newTestState(store);
      await reopened.init();
      expect(reopened.layoutFor('list').spotsFor('Moodboard').single.x, 12);
    });
  });

  testWidgets('a long menu label is shortened rather than overflowing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: ItemMenuButton(
              actions: [
                ContextMenuAction(
                  label: 'A label far longer than any narrow menu can hold',
                  icon: Icons.add,
                  onSelected: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ItemMenuButton));
    await tester.pumpAndSettle();

    // No overflow exception, which the test framework would have thrown for
    // us, and the label is there.
    expect(
      find.text('A label far longer than any narrow menu can hold'),
      findsOneWidget,
    );
  });
}

void _addingToACanvas() {
  testWidgets('what is typed goes onto the board as a card', (tester) async {
    TouchInput.debugOverride = true;
    addTearDown(() => TouchInput.debugOverride = null);
    tester.view.physicalSize = const Size(600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final state = newTestState(FakeLocalStore());
    await state.init();
    await state.createProject('List');
    await state.addBlock('list', 'Moodboard');
    await state.setCanvas('list', 'Moodboard', true);

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

    await tester.tap(find.widgetWithText(TextField, 'Moodboard'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'A thought');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    // A card in the section's markdown, not an item in a list.
    expect(state.projects.single.items, isEmpty);
    expect(state.projects.single.blocks.single.body, contains('- A thought'));
    expect(find.byType(CanvasView), findsOneWidget);
  });
}
