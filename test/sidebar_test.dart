import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/home_shell.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

/// A wide window, so the sidebar is on screen rather than the phone layout.
Future<AppState> pumpSidebar(
  WidgetTester tester,
  FakeLocalStore store,
) async {
  tester.view.physicalSize = const Size(1280, 900);
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

Future<AppState> withProjects(
  WidgetTester tester,
  FakeLocalStore store,
) async {
  final state = await pumpSidebar(tester, store);
  await state.createProject('House move');
  await state.createProject('Groceries');
  await state.createProject('Garden');
  await tester.pumpAndSettle();
  return state;
}

/// The sidebar's filter box is the first field on screen.
Finder get filterField => find.byType(TextField).first;

/// Text inside the sidebar only. The open project's title also shows in the
/// detail header beside it, so an unscoped finder counts it twice.
Finder sidebarText(String text) => find.descendant(
      of: find.byType(ProjectSidebar),
      matching: find.text(text),
    );

void main() {
  testWidgets('desktop project tabs keep sidebar switches open and can close',
      (tester) async {
    final state = await withProjects(tester, FakeLocalStore());
    state.select('groceries');
    await tester.pumpAndSettle();
    state.select('garden');
    await tester.pumpAndSettle();

    expect(find.byTooltip('Close House move tab'), findsOneWidget);
    expect(find.byTooltip('Close Groceries tab'), findsOneWidget);
    expect(find.byTooltip('Close Garden tab'), findsOneWidget);

    await tester.tap(find.byTooltip('Close Garden tab'));
    await tester.pumpAndSettle();
    expect(state.selectedSlug, 'groceries');
    expect(find.byTooltip('Close Garden tab'), findsNothing);
  });

  testWidgets('dragging a sidebar project into the tabs opens it',
      (tester) async {
    final state = await withProjects(tester, FakeLocalStore());
    final gesture = await tester.startGesture(
        tester.getCenter(sidebarText('Garden')));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(tester.getCenter(find.byTooltip('Open project tab')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(state.selectedSlug, 'garden');
    expect(find.byTooltip('Close Garden tab'), findsOneWidget);
  });

  testWidgets('the sidebar lists every project to begin with', (tester) async {
    final store = FakeLocalStore();
    await withProjects(tester, store);

    expect(sidebarText('House move'), findsOneWidget);
    expect(sidebarText('Groceries'), findsOneWidget);
    expect(sidebarText('Garden'), findsOneWidget);
  });

  testWidgets('typing in the box narrows the list to matching titles',
      (tester) async {
    final store = FakeLocalStore();
    await withProjects(tester, store);

    await tester.enterText(filterField, 'gar');
    await tester.pumpAndSettle();

    expect(sidebarText('Garden'), findsOneWidget);
    expect(sidebarText('Groceries'), findsNothing);
  });

  testWidgets('the filter ignores case', (tester) async {
    final store = FakeLocalStore();
    await withProjects(tester, store);

    await tester.enterText(filterField, 'HOUSE');
    await tester.pumpAndSettle();

    expect(sidebarText('House move'), findsOneWidget);
    expect(sidebarText('Garden'), findsNothing);
  });

  testWidgets('clearing the box brings the rest back', (tester) async {
    final store = FakeLocalStore();
    await withProjects(tester, store);

    await tester.enterText(filterField, 'gar');
    await tester.pumpAndSettle();
    await tester.enterText(filterField, '');
    await tester.pumpAndSettle();

    expect(sidebarText('Groceries'), findsOneWidget);
    expect(sidebarText('Garden'), findsOneWidget);
  });

  testWidgets('a query matching nothing says so rather than going blank',
      (tester) async {
    final store = FakeLocalStore();
    await withProjects(tester, store);

    await tester.enterText(filterField, 'zebra');
    await tester.pumpAndSettle();

    expect(find.textContaining('No project by that name'), findsOneWidget);
  });

  testWidgets('the filter only reads titles, not what is in a project',
      (tester) async {
    final store = FakeLocalStore();
    final state = await withProjects(tester, store);
    await state.addItem('garden', 'Order compost');
    await tester.pumpAndSettle();

    await tester.enterText(filterField, 'compost');
    await tester.pumpAndSettle();

    // Searching inside items is the full search screen's job.
    expect(find.textContaining('No project by that name'), findsOneWidget);
  });

  testWidgets('the Ctrl K the sidebar advertises opens the search screen',
      (tester) async {
    final store = FakeLocalStore();
    await withProjects(tester, store);

    await tester.tap(filterField);
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Search projects, items and notes'),
      findsOneWidget,
    );
  });

  testWidgets('the chip beside the box opens the same screen', (tester) async {
    final store = FakeLocalStore();
    await withProjects(tester, store);

    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Search projects, items and notes'),
      findsOneWidget,
    );
  });

  testWidgets('settings is reachable from the foot of the sidebar',
      (tester) async {
    final store = FakeLocalStore();
    await withProjects(tester, store);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Where your notes live'), findsOneWidget);
  });
}
