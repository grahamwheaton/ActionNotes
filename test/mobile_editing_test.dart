import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/checklist_view.dart';
import 'package:actionnotes/ui/context_menu.dart';
import 'package:actionnotes/ui/text_prompt.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:actionnotes/ui/touch_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

const longItem =
    'Pinch zoom on mobile needs to not move the image under it, which is '
    'a good deal longer than a single line of a phone dialog';

Future<AppState> pumpList(WidgetTester tester, {bool touch = true}) async {
  TouchInput.debugOverride = touch;
  addTearDown(() => TouchInput.debugOverride = null);

  tester.view.physicalSize = const Size(1000, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final state = newTestState(FakeLocalStore());
  await state.init();
  await state.createProject('List');
  await state.addItem('list', longItem);

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const ChecklistView(slug: 'list'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

void main() {
  group('editing an item on a phone', () {
    testWidgets('the box is deep enough to read the whole line', (
      tester,
    ) async {
      await pumpList(tester);

      await tester.tap(find.byType(ItemMenuButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();

      expect(find.text('Edit item'), findsOneWidget);

      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byType(TextPromptDialog),
          matching: find.byType(TextField),
        ),
      );
      // One line showed the end of the text and nothing else, so editing
      // anything longer than the box meant guessing at the rest.
      expect(field.minLines, greaterThan(1));
      expect(field.maxLines, greaterThan(field.minLines!));
    });
  });

  group('attaching a picture', () {
    testWidgets('the open notes offer it without opening the note fully', (
      tester,
    ) async {
      // Driven through the notes toggle rather than the phone's press-the-
      // row gesture: the button under test is the same one either way, and
      // the gesture has tests of its own.
      await pumpList(tester, touch: false);

      await tester.tap(find.byTooltip('Add notes').first);
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(TextButton, 'Image'),
        findsOneWidget,
        reason: 'it was only reachable from the full editor before',
      );
    });
  });
}
