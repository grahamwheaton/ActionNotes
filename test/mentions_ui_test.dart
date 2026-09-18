import 'package:actionnotes/markdown/note_conversation.dart';
import 'package:actionnotes/models/checklist_item.dart';
import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/state/search.dart';
import 'package:actionnotes/ui/conversation_view.dart';
import 'package:actionnotes/ui/home_shell.dart';
import 'package:actionnotes/ui/note_blocks_editor.dart';
import 'package:actionnotes/ui/search_screen.dart';
import 'package:actionnotes/ui/tag_pill.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

Project project(String title, List<ChecklistItem> items) => Project(
      slug: title.toLowerCase(),
      title: title,
      items: items,
    );

Future<AppState> pumpShell(WidgetTester tester, {Size? size}) async {
  tester.view.physicalSize = size ?? const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final state = newTestState(FakeLocalStore());
  await state.init();
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(theme: AppTheme.light(), home: const HomeShell()),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

void main() {
  group('searching for a mention', () {
    final projects = [
      project('Work', const [
        ChecklistItem(text: 'Fix the sync @Claude'),
        ChecklistItem(
          text: 'Already answered @Claude',
          notes: '**Claude** · 2026-09-18T09:12Z\nDone.',
        ),
        ChecklistItem(text: 'Nothing to do with anyone'),
      ]),
      project('Home', const [
        ChecklistItem(text: 'Ask about the van @ChatGPT'),
      ]),
    ];

    test('@name finds what is still waiting on that name', () {
      final hits = ProjectSearch.run(projects, '@claude');

      expect(hits.map((hit) => hit.text), ['Fix the sync @Claude']);
    });

    test('and nothing when it has been answered', () {
      expect(ProjectSearch.run(projects, '@nobody'), isEmpty);
    });

    test('the same text unbracketed is an ordinary search', () {
      // Plain "Claude" still matches the characters, wherever they are.
      expect(ProjectSearch.run(projects, 'Claude'), hasLength(2));
    });

    test('who is waiting, and how many each', () {
      final waiting = ProjectSearch.mentions(projects);

      // One each, so the tie breaks alphabetically.
      expect(waiting.map((w) => w.tag), ['ChatGPT', 'Claude']);
      expect(waiting.every((w) => w.count == 1), isTrue);
    });

    test('the busiest name comes first', () {
      final busier = [
        project('Work', const [
          ChecklistItem(text: 'one @Claude'),
          ChecklistItem(text: 'two @Claude'),
          ChecklistItem(text: 'three @ChatGPT'),
        ]),
      ];

      final waiting = ProjectSearch.mentions(busier);

      expect(waiting.first.tag, 'Claude');
      expect(waiting.first.count, 2);
    });
  });

  group('in the list', () {
    testWidgets('a waiting item says who it waits on', (tester) async {
      final state = await pumpShell(tester);
      await state.createProject('Work');
      await state.addItem('work', 'Fix the sync @Claude');
      await tester.pumpAndSettle();

      expect(find.byType(WaitingPill), findsOneWidget);
      expect(find.text('@Claude'), findsOneWidget);
      // The mention stays in the sentence: taking the name out would leave it
      // saying nothing.
      expect(find.textContaining('Fix the sync @Claude'), findsWidgets);
    });

    testWidgets('a reply from that name settles it', (tester) async {
      final state = await pumpShell(tester);
      await state.createProject('Work');
      await state.addItem('work', 'Fix the sync @Claude');
      await tester.pumpAndSettle();
      expect(find.byType(WaitingPill), findsOneWidget);

      await state.setItemNotes(
        'work',
        0,
        '**Claude** · 2026-09-18T09:12Z\nPicked it up.',
      );
      await tester.pumpAndSettle();

      expect(find.byType(WaitingPill), findsNothing);
    });

    testWidgets('tapping the pill searches for everything waiting',
        (tester) async {
      final state = await pumpShell(tester);
      await state.createProject('Work');
      await state.addItem('work', 'One for you @Claude');
      await state.createProject('Home');
      await state.addItem('home', 'And this @Claude');
      state.select('work');
      await tester.pumpAndSettle();

      await tester.tap(find.byType(WaitingPill).first);
      await tester.pumpAndSettle();

      expect(find.byType(SearchScreen), findsOneWidget);
      expect(find.textContaining('One for you'), findsWidgets);
      expect(find.textContaining('And this'), findsWidgets);
    });

    testWidgets('the search screen offers who is waiting', (tester) async {
      final state = await pumpShell(tester);
      await state.createProject('Work');
      await state.addItem('work', 'Over to you @Claude');
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Search').first);
      await tester.pumpAndSettle();

      expect(find.text('Waiting on'), findsOneWidget);
      expect(find.text('@Claude'), findsWidgets);
    });
  });

  group('a conversation in the row', () {
    testWidgets('opens as an exchange, not as raw markdown', (tester) async {
      final state = await pumpShell(tester);
      await state.createProject('Work');
      await state.addItem('work', 'Talked through');
      await state.setItemNotes(
        'work',
        0,
        '**Claude** · 2026-09-18T09:12Z\nFound the cause.',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Show notes'));
      await tester.pumpAndSettle();

      expect(find.byType(InlineConversation), findsOneWidget);
      expect(find.byType(NoteBlocksEditor), findsNothing);
      expect(find.text('Claude'), findsOneWidget);
      expect(find.textContaining('Found the cause'), findsOneWidget);
    });

    testWidgets('a reply is written into the note, signed', (tester) async {
      final state = await pumpShell(tester);
      await state.setLogin('grahamwheaton');
      await state.createProject('Work');
      await state.addItem('work', 'Talked through');
      await state.setItemNotes(
        'work',
        0,
        '**Claude** · 2026-09-18T09:12Z\nFound the cause.',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Show notes'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Reply'),
        'Good — ship it',
      );
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      // The row's notes settle before they are written.
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      final notes = state.projects.single.items.single.notes;
      expect(notes, contains('Found the cause.'));
      expect(notes, contains('**grahamwheaton** ·'));
      expect(notes, contains('Good — ship it'));
      expect(NoteConversation.parse(notes), hasLength(2));
    });

    testWidgets('an ordinary note is still the block editor', (tester) async {
      final state = await pumpShell(tester);
      await state.createProject('Work');
      await state.addItem('work', 'Plain');
      await state.setItemNotes('work', 0, 'Just a note.');
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Show notes'));
      await tester.pumpAndSettle();

      expect(find.byType(NoteBlocksEditor), findsOneWidget);
      expect(find.byType(InlineConversation), findsNothing);

      // And can be turned into one.
      await tester.tap(find.text('Conversation'));
      await tester.pumpAndSettle();
      expect(find.byType(InlineConversation), findsOneWidget);
    });

    testWidgets('a long exchange says how much is not shown', (tester) async {
      final state = await pumpShell(tester);
      await state.createProject('Work');
      await state.addItem('work', 'Long one');

      var notes = '';
      for (var i = 1; i <= 6; i++) {
        notes = NoteConversation.append(
          notes,
          speaker: i.isEven ? 'Claude' : 'graham',
          body: 'Message $i',
          at: DateTime.utc(2026, 9, 18, 9, i),
        );
      }
      await state.setItemNotes('work', 0, notes);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Show notes'));
      await tester.pumpAndSettle();

      expect(find.textContaining('3 earlier messages'), findsOneWidget);
      expect(find.textContaining('Message 6'), findsOneWidget);
      expect(find.textContaining('Message 1'), findsNothing);
    });
  });
}
