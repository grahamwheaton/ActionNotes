import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/canvas_screen.dart';
import 'package:actionnotes/ui/canvas_view.dart';
import 'package:actionnotes/ui/checklist_view.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:actionnotes/ui/touch_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

Future<AppState> pumpProject(WidgetTester tester, {bool touch = true}) async {
  TouchInput.debugOverride = touch;
  addTearDown(() => TouchInput.debugOverride = null);

  tester.view.physicalSize = const Size(420, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final state = newTestState(FakeLocalStore());
  await state.init();
  await state.createProject('List');
  await state.addItem('list', 'Loose');
  await state.addBlock('list', 'Shopping');
  await state.setBlockBody('list', 'Shopping', 'What we need');
  await state.addItem('list', 'Milk', block: 'Shopping');

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
  group('deleting a section', () {
    testWidgets('the menu offers it, and says what goes', (tester) async {
      await pumpProject(tester);

      await tester.tap(find.byTooltip('Section actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete section'));
      await tester.pumpAndSettle();

      expect(find.text('Delete “Shopping”?'), findsOneWidget);
      expect(find.text('Its notes and 1 item go with it.'), findsOneWidget);
    });

    testWidgets('cancelling leaves everything alone', (tester) async {
      final state = await pumpProject(tester);

      await tester.tap(find.byTooltip('Section actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete section'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(state.projects.single.blocks.length, 1);
      expect(state.projects.single.items.length, 2);
    });

    testWidgets('going ahead takes the section, its items and its notes', (
      tester,
    ) async {
      final state = await pumpProject(tester);

      await tester.tap(find.byTooltip('Section actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete section'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(state.projects.single.blocks, isEmpty);
      // The item outside the section is untouched.
      expect(state.projects.single.items.single.text, 'Loose');
    });

    test('a canvas layout goes with its section', () async {
      final state = newTestState(FakeLocalStore());
      await state.init();
      await state.createProject('List');
      await state.addBlock('list', 'Board');
      await state.setCanvas('list', 'Board', true);
      expect(state.isCanvas('list', 'Board'), isTrue);

      await state.deleteBlock('list', 'Board');
      expect(state.isCanvas('list', 'Board'), isFalse);
    });
  });

  group('folding a section away', () {
    testWidgets('hides its items and says what is in there', (tester) async {
      await pumpProject(tester);

      expect(find.text('Milk'), findsOneWidget);

      await tester.tap(find.byTooltip('Fold this section away'));
      await tester.pumpAndSettle();

      expect(find.text('Milk'), findsNothing);
      expect(find.text('1 item and notes'), findsOneWidget);
    });

    testWidgets('and brings them back', (tester) async {
      await pumpProject(tester);

      await tester.tap(find.byTooltip('Fold this section away'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Show this section'));
      await tester.pumpAndSettle();

      expect(find.text('Milk'), findsOneWidget);
    });

    testWidgets('a canvas can be folded away too', (tester) async {
      final state = await pumpProject(tester);
      await state.setCanvas('list', 'Shopping', true);
      await tester.pumpAndSettle();
      expect(find.byType(CanvasView), findsOneWidget);

      await tester.tap(find.byTooltip('Fold this section away'));
      await tester.pumpAndSettle();

      expect(find.byType(CanvasView), findsNothing);
    });
  });

  group('the full-screen canvas on a phone', () {
    testWidgets(
      'folds the adding buttons into one, leaving room for the name',
      (tester) async {
        final state = await pumpProject(tester);
        await state.setCanvas('list', 'Shopping', true);
        await state.setBlockBody('list', 'Shopping', '- A card');
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Open full screen'));
        await tester.pumpAndSettle();

        expect(find.byTooltip('Add to this canvas'), findsOneWidget);
        expect(find.byTooltip('Add photos'), findsNothing);
        // Undo and redo stay out, being reached often.
        expect(find.byTooltip('Undo'), findsOneWidget);
        await tester.pump(const Duration(seconds: 3));
      },
    );

    testWidgets('keeps the zoom controls clear of the system bar', (
      tester,
    ) async {
      tester.view.viewPadding = const FakeViewPadding(bottom: 48);
      tester.view.padding = const FakeViewPadding(bottom: 48);

      final state = await pumpProject(tester);
      await state.setCanvas('list', 'Shopping', true);
      await state.setBlockBody('list', 'Shopping', '- A card');
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Open full screen'));
      await tester.pumpAndSettle();

      final controls = tester.getRect(find.byTooltip('Fit all'));
      final screen = tester.getSize(find.byType(CanvasScreen));
      // Above the bar at the bottom, not underneath it.
      expect(controls.bottom, lessThan(screen.height - 48));
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
