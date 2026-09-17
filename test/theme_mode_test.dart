import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/settings_screen.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

void main() {
  test('the mode starts as the system default', () async {
    final state = newTestState(FakeLocalStore());
    await state.init();

    expect(state.themeMode, ThemeMode.system);
  });

  test('choosing a mode is remembered', () async {
    final settings = FakeSettingsStore();
    final store = FakeLocalStore();
    final state = AppState(localStore: store, settingsStore: settings);
    await state.init();

    await state.setThemeMode(ThemeMode.dark);

    expect(state.themeMode, ThemeMode.dark);
    expect(settings.themeMode, ThemeMode.dark);

    // A fresh start reads it back, which is the point of saving it.
    final next = AppState(localStore: store, settingsStore: settings);
    await next.init();
    expect(next.themeMode, ThemeMode.dark);
  });

  testWidgets('the picker in Settings switches it', (tester) async {
    // Tall enough for the whole settings list, so the picker is on screen.
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final settings = FakeSettingsStore();
    final state = AppState(localStore: FakeLocalStore(), settingsStore: settings);
    await state.init();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(state.themeMode, ThemeMode.dark);

    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(state.themeMode, ThemeMode.light);

    await tester.tap(find.text('System'));
    await tester.pumpAndSettle();
    expect(state.themeMode, ThemeMode.system);
  });

  testWidgets('the app follows the override, not the system', (tester) async {
    final settings = FakeSettingsStore()..themeMode = ThemeMode.dark;
    final state = AppState(localStore: FakeLocalStore(), settingsStore: settings);
    await state.init();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: Consumer<AppState>(
          builder: (context, state, _) => MaterialApp(
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: state.themeMode,
            // The system is light here; the override says otherwise.
            home: Builder(
              builder: (context) => Text(
                Theme.of(context).brightness == Brightness.dark
                    ? 'dark'
                    : 'light',
                textDirection: TextDirection.ltr,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('dark'), findsOneWidget);

    await state.setThemeMode(ThemeMode.light);
    await tester.pumpAndSettle();

    expect(find.text('light'), findsOneWidget);
  });
}
