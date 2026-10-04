import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/home_shell.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'support/fakes.dart';

void main() {
  for (final drawer in [false, true]) {
    testWidgets('PC ${drawer ? 'drawer' : 'narrow menu'} has grouped cards and sort',
        (tester) async {
      final state = newTestState(FakeLocalStore());
      await state.init();
      addTearDown(state.dispose);
      await state.createProject('Shopping');
      await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(value: state,
        child: MaterialApp(theme: AppTheme.light(), home: Scaffold(
          body: SizedBox(width: 320, child: ProjectSidebar(selectedSlug: null,
            drawerMode: drawer, pushOnTap: !drawer,
            onSelect: drawer ? state.select : null))))));
      await tester.pumpAndSettle();
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.byTooltip('Sort projects'), findsOneWidget);
      await tester.tap(find.byTooltip('Pin project'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Unpin project'), findsOneWidget);
      expect(state.projectPins, contains('shopping'));
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }
}
