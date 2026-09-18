import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/home_shell.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

Future<AppState> pumpApp(
  WidgetTester tester,
  FakeLocalStore store, {
  Size size = const Size(400, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final state = newTestState(store);

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state..init(),
      child: MaterialApp(theme: AppTheme.light(), home: const HomeShell()),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

void main() {
  testWidgets('empty state invites a first project', (tester) async {
    await pumpApp(tester, FakeLocalStore());

    expect(find.text('No projects yet'), findsOneWidget);
    expect(find.text('New project'), findsOneWidget);
  });

  testWidgets('prompts to connect GitHub when unconfigured', (tester) async {
    await pumpApp(tester, FakeLocalStore());

    expect(find.textContaining('Connect a GitHub repo'), findsOneWidget);
  });

  testWidgets('creating a project opens its checklist and saves it',
      (tester) async {
    final store = FakeLocalStore();
    await pumpApp(tester, store);

    await tester.tap(find.text('New project'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'House move');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('House move'), findsOneWidget);
    expect(find.text('Nothing here yet — add your first item below.'),
        findsOneWidget);
    expect(store.saved['house-move']?.title, 'House move');
  });

  testWidgets('items can be added and ticked off', (tester) async {
    final store = FakeLocalStore();
    final state = await pumpApp(tester, store);
    await state.createProject('Groceries');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Groceries'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Add an item'), 'Milk');
    await tester.tap(find.byTooltip('Add — hold to add it starred'));
    await tester.pumpAndSettle();

    expect(find.text('Milk'), findsOneWidget);

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();

    expect(store.saved['groceries']!.items.single.done, isTrue);
  });

  testWidgets('reordering moves an item to the index it was dropped at',
      (tester) async {
    final store = FakeLocalStore();
    final state = await pumpApp(tester, store);

    await state.createProject('Packing');
    await addItemsInOrder(state, 'packing', ['Socks', 'Shirts', 'Shoes']);

    // Drag the first item to the end, as onReorderItem reports it.
    await state.reorderSlots('packing', [0, 1, 2], 0, 2);

    expect(
      store.saved['packing']!.items.map((i) => i.text),
      ['Shirts', 'Shoes', 'Socks'],
    );

    // And back to the front.
    await state.reorderSlots('packing', [0, 1, 2], 2, 0);

    expect(
      store.saved['packing']!.items.map((i) => i.text),
      ['Socks', 'Shirts', 'Shoes'],
    );
  });

  testWidgets('the sidebar shows the open count for each project', (tester) async {
    final store = FakeLocalStore();
    final state = await pumpApp(tester, store);

    await state.createProject('Trip');
    await state.addItem('trip', 'Passport');
    await state.addItem('trip', 'Tickets');
    await state.toggleItem('trip', 0);
    await tester.pumpAndSettle();

    expect(find.text('1'), findsWidgets);
  });
}
