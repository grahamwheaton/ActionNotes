import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/storage/share_code.dart';
import 'package:actionnotes/ui/settings_screen.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_github.dart';
import 'support/fakes.dart';

void main() {
  group('who a note is signed by', () {
    test('a name set by hand wins over everything else', () async {
      final state = stateWith(FakeGitHub(), FakeLocalStore());
      await state.init();
      expect(state.me, 'graham', reason: 'the repo owner, before anything');

      await state.setDisplayName('Graham W');
      expect(state.me, 'Graham W');
      state.dispose();
    });

    test('somebody with no GitHub at all is asked for one', () async {
      // Everyone who joined with a code: no account, no repo, nothing to
      // take a name from. Every message they leave would be signed "me",
      // and so would everybody else's.
      final state = guestWith(FakeGitHub(), FakeLocalStore());
      await state.init();

      expect(state.needsName, isTrue);
      expect(state.me, 'me');

      await state.setDisplayName('Sam');
      expect(state.needsName, isFalse);
      expect(state.me, 'Sam');
      state.dispose();
    });

    test('signing in answers it without anybody being asked', () async {
      final state = guestWith(FakeGitHub(), FakeLocalStore());
      await state.init();
      await state.setLogin('samwheaton');

      expect(state.needsName, isFalse);
      expect(state.me, 'samwheaton');
      state.dispose();
    });

    test('it is remembered, not asked for again next time', () async {
      final settings = FakeSettingsStore();
      final store = FakeLocalStore();
      final first = AppState(localStore: store, settingsStore: settings);
      await first.init();
      await first.setDisplayName('Sam');
      first.dispose();

      final second = AppState(localStore: store, settingsStore: settings);
      await second.init();
      expect(second.me, 'Sam');
      second.dispose();
    });
  });

  group('joining a notebook', () {
    testWidgets('will not go ahead without a name when there is none', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final state = guestWith(FakeGitHub(), FakeLocalStore());
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

      await tester.tap(find.text('Add a notebook'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Code'),
        ShareCode.encode(theirs),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Put your name in'), findsOneWidget);
      expect(state.sharedSources, isEmpty);

      // With one, it goes through, and that is what it signs things with.
      await tester.enterText(
        find.widgetWithText(TextField, 'Your name'),
        'Sam',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(state.sharedSources, hasLength(1));
      expect(state.me, 'Sam');
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
