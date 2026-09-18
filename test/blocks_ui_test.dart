import 'package:actionnotes/markdown/project_merge.dart';
import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/checklist_view.dart';
import 'package:actionnotes/ui/context_menu.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:actionnotes/ui/touch_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

Future<AppState> pumpList(WidgetTester tester, {bool touch = false}) async {
  TouchInput.debugOverride = touch;
  addTearDown(() => TouchInput.debugOverride = null);

  tester.view.physicalSize = const Size(500, 1200);
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

void main() {
  testWidgets('a project with no sections looks exactly as it did', (
    tester,
  ) async {
    final state = await pumpList(tester);
    await state.addItem('list', 'Buy milk');
    await tester.pumpAndSettle();

    expect(state.projects.single.isFlat, isTrue);
    expect(find.byType(ItemMenuButton), findsNothing);
    expect(find.text('Buy milk'), findsOneWidget);
  });

  testWidgets('a section shows its heading and only its own items', (
    tester,
  ) async {
    final state = await pumpList(tester);
    await state.addItem('list', 'Loose item');
    await state.addBlock('list', 'Shopping');
    await state.addItem('list', 'Milk', block: 'Shopping');
    await tester.pumpAndSettle();

    expect(find.text('Shopping'), findsOneWidget);
    expect(find.text('Loose item'), findsOneWidget);
    expect(find.text('Milk'), findsOneWidget);

    // The section's item is below its heading, and the loose one above it.
    final heading = tester.getTopLeft(find.text('Shopping')).dy;
    expect(tester.getTopLeft(find.text('Milk')).dy, greaterThan(heading));
    expect(tester.getTopLeft(find.text('Loose item')).dy, lessThan(heading));
  });

  testWidgets('an item added to a section stays in it', (tester) async {
    final state = await pumpList(tester);
    await state.addBlock('list', 'Shopping');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Section actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add an item here'));
    await tester.pumpAndSettle();

    // The dialog's field, not the composer's, which is also on screen.
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'Bread',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(state.projects.single.itemsIn('Shopping').single.text, 'Bread');
  });

  testWidgets('renaming a section carries its items with it', (tester) async {
    final state = await pumpList(tester);
    await state.addBlock('list', 'Shopping');
    await state.addItem('list', 'Milk', block: 'Shopping');
    await tester.pumpAndSettle();

    await state.renameBlock('list', 'Shopping', 'Groceries');
    await tester.pumpAndSettle();

    expect(state.projects.single.blocks.single.title, 'Groceries');
    expect(state.projects.single.itemsIn('Groceries').single.text, 'Milk');
    expect(state.projects.single.itemsIn('Shopping'), isEmpty);
  });

  group('the mutations keep the file sane', () {
    test('a repeated section name is refused rather than duplicated', () async {
      final state = newTestState(FakeLocalStore());
      await state.init();
      await state.createProject('List');
      await state.addBlock('list', 'Shopping');
      await state.addBlock('list', 'Shopping');
      expect(state.projects.single.blocks.length, 1);
    });

    test('renaming onto an existing name is refused, not merged', () async {
      final state = newTestState(FakeLocalStore());
      await state.init();
      await state.createProject('List');
      await state.addBlock('list', 'A');
      await state.addBlock('list', 'B');
      await state.renameBlock('list', 'A', 'B');
      expect(state.projects.single.blocks.map((b) => b.title), ['A', 'B']);
    });

    test(
      'an item added to a section goes above that section, not the list',
      () async {
        final state = newTestState(FakeLocalStore());
        await state.init();
        await state.createProject('List');
        await state.addItem('list', 'Loose');
        await state.addBlock('list', 'Shopping');
        await state.addItem('list', 'Milk', block: 'Shopping');
        await state.addItem('list', 'Bread', block: 'Shopping');

        expect(state.projects.single.items.map((i) => i.text), [
          'Loose',
          'Bread',
          'Milk',
        ]);
        expect(state.projects.single.itemsIn(null).map((i) => i.text), [
          'Loose',
        ]);
      },
    );
  });

  group('a merge across devices', () {
    test('keeps sections from both sides and the local arrangement', () {
      final local = Project(
        slug: 'list',
        title: 'List',
        blocks: const [ProjectBlock(title: 'Shopping', body: 'mine')],
      );
      final remote = Project(
        slug: 'list',
        title: 'List',
        blocks: const [
          ProjectBlock(title: 'Shopping', body: 'theirs'),
          ProjectBlock(title: 'Later'),
        ],
      );

      final merged = ProjectMerge.merge(local: local, remote: remote);
      expect(merged.blocks.map((b) => b.title), ['Shopping', 'Later']);
      expect(merged.blocks.first.body, contains('mine'));
      expect(merged.blocks.first.body, contains('theirs'));
    });
  });
}
