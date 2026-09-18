import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/checklist_view.dart';
import 'package:actionnotes/ui/note_blocks_editor.dart';
import 'package:actionnotes/ui/search_screen.dart';
import 'package:actionnotes/ui/tag_pill.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

Future<AppState> pumpList(
  WidgetTester tester,
  List<String> items,
) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final state = newTestState(FakeLocalStore());
  await state.init();
  await state.createProject('List');
  await addItemsInOrder(state, 'list', items);

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

/// The colour of the box drawn around the row showing [text].
///
/// The row draws itself as a Material rather than a decorated box, so that an
/// ink splash lands on top of its own fill and a row lifted out to be moved
/// keeps a Material with it.
Color? rowColour(WidgetTester tester, String text) {
  final material = find
      .ancestor(of: find.text(text), matching: find.byType(Material))
      .evaluate()
      .map((element) => element.widget as Material)
      .firstWhere((widget) => widget.shape is RoundedRectangleBorder);
  return material.color;
}

void main() {
  group('tags', () {
    testWidgets('shows a tag as a pill and the title without its marker',
        (tester) async {
      await pumpList(tester, ['Fix the sync [bug]']);

      expect(find.text('Fix the sync'), findsOneWidget);
      expect(find.text('Fix the sync [bug]'), findsNothing);
      expect(find.byType(TagPill), findsOneWidget);
      expect(find.text('bug'), findsOneWidget);
    });

    testWidgets('an item with no tags is untouched', (tester) async {
      await pumpList(tester, ['Just an item']);

      expect(find.text('Just an item'), findsOneWidget);
      expect(find.byType(TagPill), findsNothing);
    });

    testWidgets('an item that is only a tag shows just the pill',
        (tester) async {
      await pumpList(tester, ['[bug]']);

      expect(find.byType(TagPill), findsOneWidget);
      expect(find.text('[bug]'), findsNothing);
      // The pill's own label is the only text on the row: no empty title
      // widget is left above it.
      final row = find.ancestor(of: find.byType(TagPill), matching: find.byType(Wrap));
      expect(find.descendant(of: row, matching: find.byType(Text)), findsOneWidget);
    });

    testWidgets('tapping a pill searches for that tag', (tester) async {
      final state = await pumpList(tester, ['Fix the sync [bug]', 'Tidy up']);
      await state.createProject('Other');
      await state.addItem('other', 'Mend the gate [bug]');
      await tester.pumpAndSettle();

      await tester.tap(find.byType(TagPill).first);
      await tester.pumpAndSettle();

      expect(find.byType(SearchScreen), findsOneWidget);
      // Both tagged items, from either project, and nothing else.
      expect(find.text('Fix the sync'), findsOneWidget);
      expect(find.text('Mend the gate'), findsOneWidget);
      expect(find.text('Tidy up'), findsNothing);
    });

    testWidgets('a tag written in a note shows on the row too', (tester) async {
      final state = await pumpList(tester, ['Fix the sync']);
      await state.setItemNotes('list', 0, 'rang them, it is [urgent]');
      await tester.pumpAndSettle();

      expect(find.byType(TagPill), findsOneWidget);
      expect(find.text('urgent'), findsOneWidget);
      // The title is untouched: nothing was taken out of it.
      expect(find.text('Fix the sync'), findsOneWidget);
    });

    testWidgets('a tag in a note is searchable like any other', (tester) async {
      final state = await pumpList(tester, ['Fix the sync']);
      await state.setItemNotes('list', 0, 'rang them, it is [urgent]');
      await tester.pumpAndSettle();

      await tester.tap(find.byType(TagPill));
      await tester.pumpAndSettle();

      expect(find.byType(SearchScreen), findsOneWidget);
      expect(find.text('Fix the sync'), findsOneWidget);
    });

    testWidgets('the markers stay in the text an edit works on',
        (tester) async {
      final state = await pumpList(tester, ['Fix the sync [bug]']);

      expect(state.projects.single.items.single.text, 'Fix the sync [bug]');
    });
  });

  group('starred rows', () {
    testWidgets('are tinted, and plain rows are not', (tester) async {
      final state = await pumpList(tester, ['Important', 'Ordinary']);

      final plain = rowColour(tester, 'Important');

      await state.toggleStar('list', 0);
      await tester.pumpAndSettle();

      final starred = rowColour(tester, 'Important');
      expect(starred, isNot(plain));
      expect(rowColour(tester, 'Ordinary'), plain);
    });

    testWidgets('go back to plain once done', (tester) async {
      final state = await pumpList(tester, ['Important']);
      final plain = rowColour(tester, 'Important');

      await state.toggleStar('list', 0);
      await tester.pumpAndSettle();
      expect(rowColour(tester, 'Important'), isNot(plain));

      await state.toggleItem('list', 0);
      await tester.pumpAndSettle();
      expect(rowColour(tester, 'Important'), plain);
    });
  });

  group('the notes section', () {
    // It used to appear only once an item had notes, which left no way to
    // find it — the complaint being that the desktop app did not show it.
    testWidgets('can be opened on an item with no notes yet', (tester) async {
      await pumpList(tester, ['Fresh']);

      expect(find.byTooltip('Add notes'), findsOneWidget);
      expect(find.byType(NoteBlocksEditor), findsNothing);

      await tester.tap(find.byTooltip('Add notes'));
      await tester.pumpAndSettle();

      expect(find.byType(NoteBlocksEditor), findsOneWidget);
      expect(find.byTooltip('Hide notes'), findsOneWidget);
    });

    testWidgets('writes what is typed into a note that did not exist',
        (tester) async {
      final state = await pumpList(tester, ['Fresh']);

      await tester.tap(find.byTooltip('Add notes'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.descendant(
          of: find.byType(NoteBlocksEditor),
          matching: find.byType(TextField),
        ),
        'typed in place',
      );
      // The write is debounced, so let it land.
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(state.projects.single.items.single.notes, contains('typed in place'));
    });

    testWidgets('says show, not add, once there is a note', (tester) async {
      final state = await pumpList(tester, ['Fresh']);
      await state.setItemNotes('list', 0, 'a note');
      await tester.pumpAndSettle();

      expect(find.byTooltip('Show notes'), findsOneWidget);
      expect(find.byTooltip('Add notes'), findsNothing);
    });
  });
}
