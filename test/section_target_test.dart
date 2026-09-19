import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/checklist_view.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:actionnotes/ui/touch_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

Future<AppState> pumpList(WidgetTester tester, {bool touch = true}) async {
  TouchInput.debugOverride = touch;
  addTearDown(() => TouchInput.debugOverride = null);

  tester.view.physicalSize = const Size(500, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final state = newTestState(FakeLocalStore());
  await state.init();
  await state.createProject('List');

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

Future<void> add(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).last, text);
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.arrow_upward));
  await tester.pumpAndSettle();
}

void main() {
  group('where a new item goes', () {
    testWidgets('the top of the project until a section is touched', (
      tester,
    ) async {
      final state = await pumpList(tester);
      await state.addBlock('list', 'Shopping');
      await tester.pumpAndSettle();

      await add(tester, 'Loose');
      expect(state.projects.single.itemsIn(null).single.text, 'Loose');
    });

    testWidgets('into the section once one has been touched, and says so', (
      tester,
    ) async {
      final state = await pumpList(tester);
      await state.addBlock('list', 'Shopping');
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextField, 'Shopping'));
      await tester.pumpAndSettle();
      expect(find.text('in Shopping'), findsOneWidget);

      await add(tester, 'Milk');
      expect(state.projects.single.itemsIn('Shopping').single.text, 'Milk');
    });

    testWidgets('back to the top when the chip is tapped', (tester) async {
      final state = await pumpList(tester);
      await state.addBlock('list', 'Shopping');
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextField, 'Shopping'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('in Shopping'));
      await tester.pumpAndSettle();

      expect(find.text('in Shopping'), findsNothing);
      await add(tester, 'Loose');
      expect(state.projects.single.itemsIn(null).single.text, 'Loose');
    });

    testWidgets('a section that is gone stops being the target', (
      tester,
    ) async {
      final state = await pumpList(tester);
      await state.addBlock('list', 'Shopping');
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextField, 'Shopping'));
      await tester.pumpAndSettle();
      expect(find.text('in Shopping'), findsOneWidget);

      await state.renameBlock('list', 'Shopping', 'Groceries');
      await tester.pumpAndSettle();

      expect(find.text('in Shopping'), findsNothing);
      await add(tester, 'Loose');
      expect(state.projects.single.itemsIn(null).single.text, 'Loose');
    });
  });

  group('a section on screen', () {
    testWidgets('shows its prose above its items, as the file has it', (
      tester,
    ) async {
      final state = await pumpList(tester);
      await state.addBlock('list', 'Shopping');
      await state.setBlockBody('list', 'Shopping', 'What we need');
      await state.addItem('list', 'Milk', block: 'Shopping');
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.text('What we need')).dy,
        lessThan(tester.getTopLeft(find.text('Milk')).dy),
      );
    });

    testWidgets('has a visible handle to drag, on a phone as well', (
      tester,
    ) async {
      final state = await pumpList(tester);
      await state.addBlock('list', 'Shopping');
      await tester.pumpAndSettle();

      // A row is moved by holding it, but a section's heading is a field its
      // name is typed into, so there is no hold to spare.
      expect(find.byIcon(Icons.drag_indicator), findsOneWidget);
    });
  });
}
