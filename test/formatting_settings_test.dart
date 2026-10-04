import 'package:actionnotes/models/view_preferences.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/formatting_settings.dart';
import 'package:actionnotes/ui/note_blocks_editor.dart';
import 'package:actionnotes/ui/settings_screen.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'support/fakes.dart';

void main() {
  testWidgets('formatting page is reachable and saves changed margins', (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = FakeSettingsStore();
    final state = newTestState(FakeLocalStore(), settingsStore: settings);
    await state.init();
    addTearDown(state.dispose);
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(value: state,
      child: MaterialApp(theme: AppTheme.light(), home: const SettingsScreen())));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Formatting'), 400,
      scrollable: find.descendant(of: find.byType(SettingsScreen),
          matching: find.byType(Scrollable)).first);
    await tester.tap(find.text('Formatting'));
    await tester.pumpAndSettle();
    expect(find.byType(FormattingSettingsScreen), findsOneWidget);
    await tester.tapAt(tester.getCenter(find.byType(Slider).first) + const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(settings.viewPreferences.formatting.horizontalMargin, greaterThan(32));
    expect(tester.takeException(), isNull);
  });

  testWidgets('prose spans the pane and live formatting preserves editing', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = newTestState(FakeLocalStore());
    await state.init();
    addTearDown(state.dispose);
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(value: state,
      child: MaterialApp(theme: AppTheme.light(), home: Scaffold(body:
        NoteBlocksEditor(initialMarkdown: 'Wide prose', onChanged: (_) {})))));
    await tester.pumpAndSettle();
    final field = find.byType(TextField).first;
    expect(tester.getSize(field).width, greaterThan(1200));
    await tester.enterText(field, 'Keep this edit');
    await state.setViewPreferences(state.viewPreferences.copyWith(formatting:
      const NoteFormatting(horizontalMargin: 64, verticalMargin: 42,
        fontSize: 20, lineHeight: 1.8)));
    await tester.pumpAndSettle();
    final widget = tester.widget<TextField>(field);
    expect(widget.controller!.text, 'Keep this edit');
    expect(widget.style!.fontSize, 20);
    expect(widget.style!.height, 1.8);
    expect(tester.getTopLeft(field).dx, greaterThanOrEqualTo(64));
    expect(tester.getTopLeft(field).dy, greaterThanOrEqualTo(42));
    expect(tester.getSize(field).width, greaterThan(1150));
    expect(tester.takeException(), isNull);
  });
}
