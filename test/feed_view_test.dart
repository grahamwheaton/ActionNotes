import 'package:actionnotes/markdown/feed_days.dart';
import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/checklist_view.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:actionnotes/ui/touch_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

String dayBefore(int days) =>
    FeedDays.titleFor(DateTime.now().subtract(Duration(days: days)));

Future<AppState> pumpFeed(
  WidgetTester tester, {
  Map<String, List<String>> days = const {},
}) async {
  TouchInput.debugOverride = false;
  addTearDown(() => TouchInput.debugOverride = null);

  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final state = newTestState(FakeLocalStore());
  await state.init();
  await state.createProject('Journal');
  await state.setMode('journal', ProjectMode.feed);

  for (final entry in days.entries) {
    await state.addBlock('journal', entry.key);
    for (final line in entry.value) {
      await state.addItem('journal', line, block: entry.key);
    }
  }

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const ChecklistView(slug: 'journal'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

void main() {
  testWidgets('a feed says which day each section is, in words', (
    tester,
  ) async {
    await pumpFeed(
      tester,
      days: {
        dayBefore(0): ['Rang the agent'],
        dayBefore(1): ['Posted the form'],
      },
    );

    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    // The date itself is not what you read; it is only what the file says.
    expect(find.text(dayBefore(0)), findsNothing);
  });

  testWidgets('today is open and the days before it are folded', (
    tester,
  ) async {
    await pumpFeed(
      tester,
      days: {
        dayBefore(0): ['Rang the agent'],
        dayBefore(1): ['Posted the form'],
      },
    );

    expect(find.text('Rang the agent'), findsOneWidget);
    // Folded rather than gone: a feed is what happened today, with the rest
    // there when it is asked for.
    expect(find.text('Posted the form'), findsNothing);

    await tester.tap(find.text('Yesterday'));
    await tester.pumpAndSettle();
    expect(find.text('Posted the form'), findsOneWidget);
  });

  testWidgets('a day opened stays open as the screen rebuilds', (tester) async {
    final state = await pumpFeed(
      tester,
      days: {
        dayBefore(0): ['Rang the agent'],
        dayBefore(1): ['Posted the form'],
      },
    );

    await tester.tap(find.text('Yesterday'));
    await tester.pumpAndSettle();
    expect(find.text('Posted the form'), findsOneWidget);

    // Something else changes, so the whole screen builds again.
    await state.addItem('journal', 'Another thing', block: dayBefore(0));
    await tester.pumpAndSettle();

    expect(find.text('Posted the form'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('newest day first, whatever order the file is in', (
    tester,
  ) async {
    await pumpFeed(
      tester,
      days: {
        dayBefore(2): ['Oldest'],
        dayBefore(0): ['Newest'],
        dayBefore(1): ['Middle'],
      },
    );

    final today = tester.getRect(find.text('Today'));
    final yesterday = tester.getRect(find.text('Yesterday'));
    expect(today.top, lessThan(yesterday.top));
  });

  testWidgets('what is written goes under today, making it if it is new', (
    tester,
  ) async {
    final state = await pumpFeed(tester);

    await tester.enterText(find.byType(TextField).last, 'Rang the agent');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    final project = state.projectBySlug('journal')!;
    expect(project.blocks.single.title, dayBefore(0));
    expect(project.items.single.text, 'Rang the agent');
    expect(project.items.single.block, dayBefore(0));

    // And the day it just made is open, not folded away the moment it
    // appears.
    expect(find.text('Rang the agent'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a second thing written today joins the same day', (
    tester,
  ) async {
    final state = await pumpFeed(
      tester,
      days: {
        dayBefore(0): ['Rang the agent'],
      },
    );

    await tester.enterText(find.byType(TextField).last, 'Posted the form');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    final project = state.projectBySlug('journal')!;
    expect(project.blocks, hasLength(1));
    expect(project.items, hasLength(2));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a feed is an ordinary file, readable anywhere', (tester) async {
    final state = await pumpFeed(
      tester,
      days: {
        dayBefore(0): ['Rang the agent'],
      },
    );

    final saved = (state.projectBySlug('journal'))!;
    // Sections that are dates and items under them: what anyone would have
    // written by hand, and what GitHub shows without knowing anything.
    expect(saved.mode, ProjectMode.feed);
    expect(saved.blocks.single.title, dayBefore(0));
    expect(saved.itemsIn(dayBefore(0)).single.text, 'Rang the agent');
  });

  testWidgets('turning a checklist into a feed, and back', (tester) async {
    final state = await pumpFeed(tester);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn into a checklist'));
    await tester.pumpAndSettle();

    expect(state.projectBySlug('journal')!.mode, ProjectMode.tasks);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn into a feed'));
    await tester.pumpAndSettle();

    expect(state.projectBySlug('journal')!.mode, ProjectMode.feed);
    await tester.pump(const Duration(seconds: 3));
  });
}
