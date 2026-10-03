import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/home_shell.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('PC cards filter pins and retain groups and project tabs',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = newTestState(FakeLocalStore());
    await state.init();
    addTearDown(state.dispose);
    await state.createProject('Shopping');
    await state.createProject('Ideas');
    await state.setMode('ideas', ProjectMode.notes);
    await state.addGroup('Home');
    await state.placeProject('shopping', group: 'Home');
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(theme: AppTheme.light(), home: const HomeShell()),
    ));
    await tester.pumpAndSettle();
    final sidebar = find.byType(ProjectSidebar);
    Finder text(String value) => find.descendant(of: sidebar,
        matching: find.text(value));
    expect(text('Home'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.descendant(of: sidebar,
        matching: find.byTooltip('Pin project')).first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(text('Pinned'));
    await tester.tap(text('Pinned'));
    await tester.pumpAndSettle();
    expect(text('Ideas'), findsOneWidget);
    expect(text('Shopping'), findsNothing);
    await tester.tap(text('Ideas'));
    await tester.pumpAndSettle();
    expect(state.selectedSlug, 'ideas');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('android_pinned_projects'), contains('ideas'));
    await tester.ensureVisible(text('Groups'));
    await tester.tap(text('Groups'));
    await tester.pumpAndSettle();
    await tester.tap(text('Home'));
    await tester.pumpAndSettle();
    expect(text('Shopping'), findsNothing);
    await tester.tap(text('Home'));
    await tester.pumpAndSettle();
    expect(text('Shopping'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
