import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/models/checklist_item.dart';
import 'package:actionnotes/models/view_preferences.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/home_shell.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('$platform project panel layouts update immediately', (tester) async {
      tester.view.physicalSize = Size(platform == TargetPlatform.android ? 400 : 1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = FakeLocalStore();
      store.saved['sample'] = Project(slug: 'sample', title: 'Sample project',
        updated: DateTime(2026, 1, 1), items: const [ChecklistItem(text: 'One')]);
      final state = newTestState(store);
      await state.init();
      addTearDown(state.dispose);
      await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(value: state,
        child: MaterialApp(theme: AppTheme.light(), home: const HomeShell())));
      await tester.pumpAndSettle();
      final root = platform == TargetPlatform.windows
        ? find.byType(ProjectSidebar) : find.byType(Scaffold).first;
      Finder text(String value) => find.descendant(of: root, matching: find.text(value));
      expect(text('Tasks'), findsNothing);
      expect(text('1'), findsOneWidget);
      expect(text('1/1/2026'), findsOneWidget);
      final title = text('Sample project');
      final mediumFont = tester.widget<Text>(title).style!.fontSize!;
      final row = find.ancestor(of: title, matching: find.byType(InkWell)).first;
      final mediumHeight = tester.getSize(row).height;
      await state.setViewPreferences(state.viewPreferences.copyWith(
        projectPanelStyle: ProjectPanelStyle.compact));
      await tester.pumpAndSettle();
      expect(text('1'), findsNothing);
      expect(text('1/1/2026'), findsNothing);
      expect(text('Sample project'), findsOneWidget);
      expect(tester.getSize(row).height, lessThanOrEqualTo(mediumHeight));
      await state.setViewPreferences(state.viewPreferences.copyWith(
        projectPanelStyle: ProjectPanelStyle.detailed));
      await tester.pumpAndSettle();
      expect(text('Tasks'), findsOneWidget);
      expect(text('1'), findsOneWidget);
      expect(tester.widget<Text>(title).style!.fontSize!, lessThan(mediumFont));
      expect(tester.getSize(row).height, greaterThan(mediumHeight));
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(platform));
    testWidgets('$platform groups, pins and sorting stay in step', (tester) async {
      tester.view.physicalSize = Size(platform == TargetPlatform.android ? 400 : 1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = FakeLocalStore();
      store.saved.addAll({
        'alpha': Project(slug: 'alpha', title: 'Alpha', updated: DateTime(2026, 1, 1)),
        'beta': Project(slug: 'beta', title: 'Beta', updated: DateTime(2026, 1, 2),
          items: const [ChecklistItem(text: 'Important', starred: true)]),
        'gamma': Project(slug: 'gamma', title: 'Gamma', updated: DateTime(2026, 1, 3)),
      });
      final settings = FakeSettingsStore();
      final state = newTestState(store, settingsStore: settings);
      await state.init();
      addTearDown(state.dispose);
      await state.addGroup('Work');
      await state.placeProject('beta', group: 'Work');
      await state.placeProject('gamma', group: 'Work');
      await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(value: state,
        child: MaterialApp(theme: AppTheme.light(), home: const HomeShell())));
      await tester.pumpAndSettle();
      final root = platform == TargetPlatform.windows
          ? find.byType(ProjectSidebar) : find.byType(Scaffold).first;
      Finder text(String value) => find.descendant(of: root, matching: find.text(value));
      double y(String value) => tester.getTopLeft(text(value).first).dy;
      expect(find.byType(ChoiceChip), findsNothing);
      expect(text('Work'), findsOneWidget);
      expect(y('Gamma'), lessThan(y('Beta')));
      await state.toggleProjectPin('gamma');
      await tester.pumpAndSettle();
      expect(y('Gamma'), lessThan(y('Alpha')));
      expect(text('Gamma'), findsOneWidget);
      await tester.tap(find.descendant(of: root, matching: find.byTooltip('Sort projects')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckedPopupMenuItem<ProjectSort>, 'Stars'));
      await tester.pumpAndSettle();
      expect(state.viewPreferences.projectSort, ProjectSort.stars);
      await state.toggleProjectPin('gamma');
      await tester.pumpAndSettle();
      expect(y('Beta'), lessThan(y('Gamma')));
      await tester.tap(text('Work'));
      await tester.pumpAndSettle();
      expect(text('Beta'), findsNothing);
      await tester.tap(text('Work'));
      await tester.pumpAndSettle();
      expect(text('Beta'), findsOneWidget);
      await state.toggleProjectPin('beta');
      await tester.pumpAndSettle();
      if (platform == TargetPlatform.android) {
        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pumpAndSettle();
        final sidebar = find.byType(ProjectSidebar);
        expect(find.descendant(of: sidebar, matching: find.text('Stars')), findsOneWidget);
        expect(find.descendant(of: sidebar, matching: find.byTooltip('Unpin project')), findsOneWidget);
      }
      final before = state.viewPreferences.sidebarWidth;
      await tester.drag(find.byKey(const ValueKey('sidebar_resize_handle')), const Offset(50, 0));
      await tester.pumpAndSettle();
      expect(state.viewPreferences.sidebarWidth, greaterThan(before));
      expect(settings.viewPreferences.sidebarWidth, state.viewPreferences.sidebarWidth);
      final restarted = newTestState(store, settingsStore: settings);
      await restarted.init();
      addTearDown(restarted.dispose);
      expect(restarted.projectPins, contains('beta'));
      expect(restarted.viewPreferences.projectSort, ProjectSort.stars);
      expect(restarted.viewPreferences.sidebarWidth, state.viewPreferences.sidebarWidth);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(platform));
  }
}
