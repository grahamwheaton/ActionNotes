import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/home_shell.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('phone drawer switches projects and identifies their type',
      (tester) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = newTestState(FakeLocalStore());
    await state.init();
    await state.createProject('Shopping');
    await state.createProject('Ideas');
    await state.setMode('ideas', ProjectMode.notes);
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(theme: AppTheme.light(), home: const HomeShell()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Shopping').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Tasks project'), findsOneWidget);
    expect(find.byTooltip('Notes project'), findsOneWidget);
    await tester.tap(find.text('Ideas').first);
    await tester.pumpAndSettle();
    expect(find.text('Ideas'), findsWidgets);
    expect(find.byType(Drawer), findsOneWidget);
  });
}
