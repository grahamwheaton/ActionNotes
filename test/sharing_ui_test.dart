import 'dart:async';

import 'package:actionnotes/models/notes_source.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/storage/share_code.dart';
import 'package:actionnotes/ui/home_shell.dart';
import 'package:actionnotes/ui/settings_screen.dart';
import 'package:actionnotes/ui/shared_notebooks.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_github.dart';
import 'support/fakes.dart';

Future<void> pump(WidgetTester tester, AppState state, Widget screen) async {
  tester.view.physicalSize = const Size(1000, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(theme: AppTheme.light(), home: screen),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('the shared notebooks section', () {
    testWidgets('says what one is when there are none, and offers to add', (
      tester,
    ) async {
      final state = stateWith(FakeGitHub(), FakeLocalStore());
      await state.init();
      await pump(tester, state, const SettingsScreen());

      expect(find.text('Shared notebooks'), findsOneWidget);
      expect(find.text('Add a notebook'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a pasted code adds a notebook, and it is listed by name', (
      tester,
    ) async {
      final state = stateWith(FakeGitHub(), FakeLocalStore());
      await state.init();
      await pump(tester, state, const SettingsScreen());

      await tester.tap(find.text('Add a notebook'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Code'),
        ShareCode.encode(theirs),
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Call it (optional)'),
        'Kitchen',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(state.sharedSources, hasLength(1));
      // Called what they called it, not what the repo is called: the repo
      // name is a thing they never chose and may never have seen.
      expect(find.text('Kitchen'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a code that is not one says so, and nothing is added', (
      tester,
    ) async {
      final state = stateWith(FakeGitHub(), FakeLocalStore());
      await state.init();
      await pump(tester, state, const SettingsScreen());

      await tester.tap(find.text('Add a notebook'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Code'),
        'have a nice day',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(
        find.text('That does not look like a share code.'),
        findsOneWidget,
      );
      expect(state.sharedSources, isEmpty);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('setting one up asks for a token for that repo alone', (
      tester,
    ) async {
      final state = stateWith(FakeGitHub(), FakeLocalStore());
      await state.init();
      await pump(tester, state, const SettingsScreen());

      await tester.tap(find.text('Add a notebook'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set one up'));
      await tester.pumpAndSettle();

      // The sentence that keeps somebody from pasting the token that reaches
      // everything they have, which is what the code would then carry.
      expect(
        find.textContaining('that one repository and nothing else'),
        findsOneWidget,
      );
      // Nothing can be picked until there is a token to list repos with.
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Pick repository'),
            )
            .onPressed,
        isNull,
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Set it up'));
      await tester.pumpAndSettle();
      expect(
        find.text('Paste the token, then pick the repository.'),
        findsOneWidget,
      );
      expect(state.sharedSources, isEmpty);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('giving a notebook up is asked about, and says what it does', (
      tester,
    ) async {
      final state = stateWith(FakeGitHub(), FakeLocalStore());
      await state.init();
      await state.addSharedNotebook(ShareCode.encode(theirs), label: 'Kitchen');
      await pump(tester, state, const SettingsScreen());

      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();

      expect(find.text('Stop using Kitchen?'), findsOneWidget);
      // The sentence that matters: this is not a deletion.
      expect(find.textContaining('Nothing in it is deleted'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Stop using it'));
      await tester.pumpAndSettle();

      expect(state.sharedSources, isEmpty);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('the code you hand out', () {
    testWidgets('is shown, says plainly what it grants, and copies', (
      tester,
    ) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      final state = stateWith(FakeGitHub(), FakeLocalStore());
      await state.init();
      await state.addSharedNotebook(ShareCode.encode(theirs), label: 'Kitchen');
      await pump(tester, state, const SettingsScreen());

      await tester.tap(find.widgetWithText(TextButton, 'Share'));
      await tester.pumpAndSettle();

      expect(find.text('Share Kitchen'), findsOneWidget);
      // Nobody should be able to send this without having read what it is.
      expect(
        find.textContaining('can read and change everything'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Copy code'));
      await tester.pumpAndSettle();

      expect(copied.single, ShareCode.encode(theirs));
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('sharing a project', () {
    testWidgets('with no notebook yet, it offers to add one first', (
      tester,
    ) async {
      final state = stateWith(FakeGitHub(), FakeLocalStore());
      await state.init();
      await state.createProject('Shopping');
      await pump(
        tester,
        state,
        const Scaffold(body: ProjectSidebar(selectedSlug: null)),
      );

      unawaited(
        ShareProjectDialog.show(
          tester.element(find.text('Shopping')),
          state.projectBySlug('shopping')!,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No shared notebook yet'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('moves it into the notebook that is picked', (tester) async {
      final state = stateWith(FakeGitHub(), FakeLocalStore());
      await state.init();
      await state.createProject('Shopping');
      await state.addSharedNotebook(ShareCode.encode(theirs), label: 'Kitchen');
      await pump(
        tester,
        state,
        const Scaffold(body: ProjectSidebar(selectedSlug: null)),
      );

      // Not awaited: the picker is open until something is chosen, and
      // choosing is what the rest of the test does.
      unawaited(
        ShareProjectDialog.show(
          tester.element(find.text('Shopping')),
          state.projectBySlug('shopping')!,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Kitchen'));
      await tester.pumpAndSettle();

      final moved = state.projects.single;
      expect(moved.title, 'Shopping');
      expect(moved.isShared, isTrue);
      expect(moved.sourceId, NotesSource.idFor(theirs));
      // The file underneath keeps its own plain name; only the key the app
      // holds it by says which notebook it is in.
      expect(moved.fileSlug, 'shopping');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a shared project is marked as one in the sidebar', (
      tester,
    ) async {
      final state = stateWith(FakeGitHub(), FakeLocalStore());
      await state.init();
      await state.createProject('Shopping');
      await state.addSharedNotebook(ShareCode.encode(theirs), label: 'Kitchen');
      await pump(
        tester,
        state,
        const Scaffold(body: ProjectSidebar(selectedSlug: null)),
      );

      expect(find.byIcon(Icons.folder_shared_outlined), findsNothing);

      await state.moveProject('shopping', NotesSource.idFor(theirs));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.folder_shared_outlined), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
