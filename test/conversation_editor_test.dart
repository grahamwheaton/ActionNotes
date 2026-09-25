import 'package:actionnotes/markdown/note_conversation.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/conversation_view.dart';
import 'package:actionnotes/ui/home_shell.dart';
import 'package:actionnotes/ui/note_blocks_editor.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

/// Opens an item's note editor with [notes] already in it.
Future<AppState> openNote(
  WidgetTester tester,
  FakeLocalStore store, {
  required String notes,
  String? login,
}) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final state = newTestState(store);
  await state.init();
  if (login != null) await state.setLogin(login);

  await state.createProject('List');
  await state.addItem('list', 'Item');
  if (notes.isNotEmpty) await state.setItemNotes('list', 0, notes);

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(theme: AppTheme.light(), home: const HomeShell()),
    ),
  );
  await tester.pumpAndSettle();

  await tester.tap(find.text('Item'));
  await tester.pumpAndSettle();
  return state;
}

Finder composer() => find.widgetWithText(TextField, 'Write a message');

void main() {
  testWidgets('a note with signed messages opens as a conversation', (
    tester,
  ) async {
    await openNote(
      tester,
      FakeLocalStore(),
      notes: '**Claude** · 2026-09-18T09:12Z\nFixed the sync bug.',
    );

    expect(find.byType(ConversationView), findsOneWidget);
    expect(find.text('Claude'), findsOneWidget);
    expect(find.textContaining('Fixed the sync bug'), findsOneWidget);
    // The block editor is not in the way of it.
    expect(find.byType(NoteBlocksEditor), findsNothing);
  });

  testWidgets('an update keeps an unsent message in the open app', (
    tester,
  ) async {
    final state = await openNote(
      tester,
      FakeLocalStore(),
      notes: '**Claude**\nDone.',
    );
    await tester.enterText(composer(), 'Unsent reply');
    await expectLater(
      state.prepareForUpdate(),
      throwsA(isA<UpdatePreparationException>()),
    );
    expect(find.text('Unsent reply'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('an ordinary note opens as the editor it always was', (
    tester,
  ) async {
    await openNote(tester, FakeLocalStore(), notes: 'Just a note.');

    expect(find.byType(NoteBlocksEditor), findsOneWidget);
    expect(find.byType(ConversationView), findsNothing);
  });

  testWidgets('a message is written into the note, signed', (tester) async {
    final store = FakeLocalStore();
    final state = await openNote(
      tester,
      store,
      notes: '**Claude** · 2026-09-18T09:12Z\nDone.',
      login: 'grahamwheaton',
    );

    await tester.enterText(composer(), 'Thanks, does it need a release?');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    final notes = state.projects.single.items.single.notes;
    expect(notes, contains('Done.'));
    expect(notes, contains('**grahamwheaton** ·'));
    expect(notes, contains('Thanks, does it need a release?'));

    // And it reads back as a two-sided conversation.
    final messages = NoteConversation.parse(notes);
    expect(messages.map((m) => m.speaker), ['Claude', 'grahamwheaton']);
  });

  testWidgets('the composer empties, so a message cannot be sent twice', (
    tester,
  ) async {
    final state = await openNote(tester, FakeLocalStore(), notes: '**c**\nhi');

    await tester.enterText(composer(), 'One message');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    final notes = state.projects.single.items.single.notes;
    expect('One message'.allMatches(notes), hasLength(1));
  });

  testWidgets('the views switch, and carry the note with them', (tester) async {
    final state = await openNote(
      tester,
      FakeLocalStore(),
      notes: '**Claude** · 2026-09-18T09:12Z\nDone.',
      login: 'graham',
    );

    await tester.enterText(composer(), 'A message from the chat');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Edit as markdown'));
    await tester.pumpAndSettle();

    // The markdown editor holds the message that was just sent, signature and
    // all, rather than the note as it was when the editor opened.
    expect(find.byType(NoteBlocksEditor), findsOneWidget);
    expect(find.textContaining('A message from the chat'), findsWidgets);

    await tester.tap(find.byTooltip('Conversation'));
    await tester.pumpAndSettle();

    expect(find.byType(ConversationView), findsOneWidget);
    expect(
      state.projects.single.items.single.notes,
      contains('A message from the chat'),
    );
  });

  testWidgets('a plain note can be turned into a conversation', (tester) async {
    final state = await openNote(
      tester,
      FakeLocalStore(),
      notes: 'An older plain note.',
      login: 'graham',
    );

    await tester.tap(find.byTooltip('Conversation'));
    await tester.pumpAndSettle();

    // What was there is kept, attributed to nobody.
    expect(find.textContaining('An older plain note'), findsOneWidget);

    await tester.enterText(composer(), 'Carrying on');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    final notes = state.projects.single.items.single.notes;
    expect(notes, startsWith('An older plain note.'));
    expect(notes, contains('**graham** ·'));
  });

  testWidgets('an empty note says what the conversation is for', (
    tester,
  ) async {
    await openNote(tester, FakeLocalStore(), notes: '');

    await tester.tap(find.byTooltip('Conversation'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Nothing said yet'), findsOneWidget);
  });
}
