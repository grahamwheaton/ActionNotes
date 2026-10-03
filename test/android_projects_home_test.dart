import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/home_shell.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('Android pins persist and groups still collapse', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
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
    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.tap(find.byTooltip('Pin project').first);
    await tester.pumpAndSettle();
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getStringList('android_pinned_projects'), hasLength(1));
    await tester.tap(find.text('Pinned 1'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Unpin project'), findsOneWidget);
    expect(find.byTooltip('Pin project'), findsNothing);
    await tester.tap(find.text('Groups'));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Shopping'), findsOneWidget);
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(find.text('Shopping'), findsNothing);
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shopping'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ideas').first);
    await tester.pumpAndSettle();
    expect(find.text('Ideas'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows keeps its existing project layout', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = newTestState(FakeLocalStore());
    await state.init();
    addTearDown(state.dispose);
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(theme: AppTheme.light(), home: const HomeShell()),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(ProjectSidebar), findsOneWidget);
  });
}
