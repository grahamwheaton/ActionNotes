import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/storage/github_client.dart';
import 'package:actionnotes/ui/home_shell.dart';
import 'package:actionnotes/ui/settings_screen.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

Future<AppState> pumpSettings(
  WidgetTester tester, {
  GitHubConfig? config,
}) async {
  tester.view.physicalSize = const Size(900, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final state = newTestState(FakeLocalStore(), config: config);
  await state.init();

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(theme: AppTheme.light(), home: const SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

Future<AppState> pumpShell(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final state = newTestState(FakeLocalStore());
  await state.init();
  await state.createProject('List');
  await state.addItem('list', 'An item');

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(theme: AppTheme.light(), home: const HomeShell()),
    ),
  );
  await tester.pumpAndSettle();
  // The keys are caught above the app, so something in it has to have the
  // keyboard first — which in use it always does.
  await tester.tap(find.byType(TextField).last);
  await tester.pumpAndSettle();
  return state;
}

void main() {
  group('the owner and the branch in settings', () {
    testWidgets('are folded away once something has filled them in', (
      tester,
    ) async {
      await pumpSettings(tester, config: testConfig);

      // Said out loud rather than hidden: what is going to be written to
      // should be readable without opening anything.
      expect(find.text('graham/notes on main'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Owner'), findsNothing);
      expect(find.widgetWithText(TextField, 'Branch'), findsNothing);
      // The repository is still a field, because it is the one people
      // actually choose.
      expect(find.widgetWithText(TextField, 'Repository'), findsOneWidget);
    });

    testWidgets('come back on Change, because a different owner is a real '
        'thing to want', (tester) async {
      await pumpSettings(tester, config: testConfig);

      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'Owner'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Branch'), findsOneWidget);
      expect(find.text('graham/notes on main'), findsNothing);
    });

    testWidgets('are shown from the start when nothing has filled them', (
      tester,
    ) async {
      await pumpSettings(tester);

      expect(find.widgetWithText(TextField, 'Owner'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Branch'), findsOneWidget);
      expect(find.text('Change'), findsNothing);
    });
  });

  group('the shortcuts sheet', () {
    testWidgets('opens on F1', (tester) async {
      await pumpShell(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      await tester.pumpAndSettle();

      expect(find.text('Keyboard shortcuts'), findsOneWidget);
    });

    testWidgets('opens on Ctrl and slash', (tester) async {
      await pumpShell(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(find.text('Keyboard shortcuts'), findsOneWidget);
    });

    testWidgets('no longer takes shift and slash, which is how a question '
        'mark is typed', (tester) async {
      await pumpShell(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();

      expect(find.text('Keyboard shortcuts'), findsNothing);
    });

    testWidgets('so a question mark can be written into a task', (
      tester,
    ) async {
      final state = await pumpShell(tester);

      await tester.enterText(find.byType(TextField).last, 'Ring the agent?');
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();

      expect(find.text('Keyboard shortcuts'), findsNothing);

      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pumpAndSettle();

      expect(state.projectBySlug('list')!.items.first.text, 'Ring the agent?');
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
