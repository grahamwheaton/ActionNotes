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

Future<AppState> pumpProject(
  WidgetTester tester, {
  String body = '- One card\n- Another card',
  bool touch = false,
}) async {
  TouchInput.debugOverride = touch;
  addTearDown(() => TouchInput.debugOverride = null);

  tester.view.physicalSize = const Size(900, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final state = newTestState(FakeLocalStore());
  await state.init();
  await state.createProject('List');
  await state.addBlock('list', 'Moodboard');
  await state.setBlockBody('list', 'Moodboard', body);
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
  return state;
}

void main() {
  group('opening a canvas full screen', () {
    testWidgets('from the button on the canvas itself', (tester) async {
      await pumpProject(tester);

      await tester.tap(find.byTooltip('Open full screen'));
      await tester.pumpAndSettle();

      expect(find.byType(CanvasScreen), findsOneWidget);
      // The same cards, on a screen of its own.
      expect(find.text('One card'), findsOneWidget);
    });

    testWidgets('from the section menu', (tester) async {
      await pumpProject(tester, touch: true);

      await tester.tap(find.byTooltip('Section actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open full screen'));
      await tester.pumpAndSettle();

      expect(find.byType(CanvasScreen), findsOneWidget);
    });

    testWidgets('it is not a second copy — a move made there is the move', (
      tester,
    ) async {
      final state = await pumpProject(tester);

      await tester.tap(find.byTooltip('Open full screen'));
      await tester.pumpAndSettle();

      await tester.drag(find.text('One card'), const Offset(120, 80));
      await tester.pumpAndSettle();

      final spot = state.layoutFor('list').spotsFor('Moodboard').first;
      expect(spot.x, greaterThan(100));
      // The layout settles on a two-second timer before it is written.
      await tester.pump(const Duration(seconds: 3));

      // And the section's markdown is untouched by moving something.
      expect(
        state.projects.single.blocks.single.body,
        '- One card\n- Another card',
      );
    });

    testWidgets('a canvas whose section has gone says so', (tester) async {
      final state = await pumpProject(tester);

      await tester.tap(find.byTooltip('Open full screen'));
      await tester.pumpAndSettle();

      await state.renameBlock('list', 'Moodboard', 'Elsewhere');
      await tester.pumpAndSettle();

      expect(find.text('This canvas is no longer here.'), findsOneWidget);
    });
  });

  group('a card on the canvas', () {
    testWidgets('can be deleted, and takes its position with it', (
      tester,
    ) async {
      final state = await pumpProject(tester);

      await tester.tap(find.byTooltip('Open full screen'));
      await tester.pumpAndSettle();

      // Put the second card somewhere findable first.
      await tester.drag(find.text('Another card'), const Offset(60, 60));
      await tester.pumpAndSettle();
      expect(state.layoutFor('list').spotsFor('Moodboard').length, 2);

      await tester.longPress(find.text('One card'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete card'));
      await tester.pumpAndSettle();

      expect(state.projects.single.blocks.single.body, '- Another card');
      expect(state.layoutFor('list').spotsFor('Moodboard').length, 1);
      // The position that is left is the one that belonged to the card that
      // is left, not the dead one shifted along.
      expect(
        state.layoutFor('list').spotsFor('Moodboard').single.ref,
        'Another card',
      );
    });

    testWidgets('can be sent to the back', (tester) async {
      final state = await pumpProject(tester);

      await tester.tap(find.byTooltip('Open full screen'));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Another card'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send to back'));
      await tester.pumpAndSettle();

      final spots = state.layoutFor('list').spotsFor('Moodboard');
      expect(spots[1].z, lessThan(spots[0].z));
      // The layout settles on a two-second timer before it is written.
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('nudges by a pixel with the arrow keys', (tester) async {
      final state = await pumpProject(tester);

      await tester.tap(find.byTooltip('Open full screen'));
      await tester.pumpAndSettle();

      // Move it once so there is a position on record to nudge from — until
      // something is moved, where the cards sit is worked out by the view and
      // nothing has been written.
      await tester.drag(find.text('One card'), const Offset(50, 50));
      await tester.pumpAndSettle();

      await tester.tap(find.text('One card'));
      await tester.pumpAndSettle();

      final before = state.layoutFor('list').spotsFor('Moodboard').first;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      final after = state.layoutFor('list').spotsFor('Moodboard').first;
      expect(after.x, closeTo(before.x + 1, 0.01));
      // The layout settles on a two-second timer before it is written.
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('adding to a full-screen canvas', () {
    testWidgets('a note goes on as a card', (tester) async {
      final state = await pumpProject(tester);

      await tester.tap(find.byTooltip('Open full screen'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add a note'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'A new thought',
      );
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(
        state.projects.single.blocks.single.body,
        contains('- A new thought'),
      );
      expect(find.text('A new thought'), findsOneWidget);
    });

    testWidgets('an empty canvas offers the way to fill it', (tester) async {
      await pumpProject(tester, body: '');

      await tester.tap(find.text('Open full screen to add photos'));
      await tester.pumpAndSettle();

      expect(find.byType(CanvasScreen), findsOneWidget);
      expect(find.byTooltip('Add photos'), findsOneWidget);
    });
  });
}
