import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/context_menu.dart';
import 'package:actionnotes/ui/home_shell.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

Future<AppState> pumpSidebar(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final state = newTestState(FakeLocalStore());
  await state.init();
  await state.createProject('Quote');
  await state.createProject('Shopping');

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: ProjectSidebar(selectedSlug: null)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

void main() {
  group('groups in the sidebar', () {
    testWidgets('one can be made, and a project put in it', (tester) async {
      final state = await pumpSidebar(tester);

      await tester.tap(find.byTooltip('New group'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Work');
      await tester.tap(find.widgetWithText(FilledButton, 'Make it'));
      await tester.pumpAndSettle();

      expect(find.text('Work'), findsOneWidget);
      expect(state.sidebar.groups.single.name, 'Work');

      // The menu path, which is what a phone has instead of dragging.
      await tester.tap(find.byType(ItemMenuButton).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move to group…'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Work'));
      await tester.pumpAndSettle();

      expect(state.groupOf('quote')!.name, 'Work');
      expect(state.looseProjects.map((p) => p.title), ['Shopping']);
    });

    testWidgets('a group folds away and remembers that it is folded', (
      tester,
    ) async {
      final state = await pumpSidebar(tester);
      await state.addGroup('Work');
      await state.placeProject('quote', group: 'Work');
      await tester.pumpAndSettle();

      expect(find.text('Quote'), findsOneWidget);

      await tester.tap(find.text('Work'));
      await tester.pumpAndSettle();

      expect(find.text('Quote'), findsNothing);
      expect(state.sidebar.groups.single.collapsed, isTrue);
      // Shopping is not in it, so folding Work away leaves it alone.
      expect(find.text('Shopping'), findsOneWidget);
    });

    testWidgets('ungrouping keeps the projects that were in it', (
      tester,
    ) async {
      final state = await pumpSidebar(tester);
      await state.addGroup('Work');
      await state.placeProject('quote', group: 'Work');
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Group actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ungroup these'));
      await tester.pumpAndSettle();

      expect(state.sidebar.groups, isEmpty);
      expect(
        state.looseProjects.map((p) => p.title),
        containsAll(['Quote', 'Shopping']),
        reason: 'a group is a way of looking at a list, not where it lives',
      );
      expect(find.text('Quote'), findsOneWidget);
    });

    testWidgets('searching sets the groups aside and shows every match', (
      tester,
    ) async {
      final state = await pumpSidebar(tester);
      await state.addGroup('Work');
      await state.placeProject('quote', group: 'Work');
      await state.toggleGroup('Work');
      await tester.pumpAndSettle();

      // Folded away, so it cannot be seen.
      expect(find.text('Quote'), findsNothing);

      await tester.enterText(find.byType(TextField).first, 'quo');
      await tester.pumpAndSettle();

      // You are looking for a project, not for where you filed it.
      expect(find.text('Quote'), findsOneWidget);
      expect(find.text('Work'), findsNothing);
    });
  });
}
