import 'dart:convert';

import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/storage/github_client.dart';
import 'package:actionnotes/storage/sync_service.dart';
import 'package:actionnotes/ui/checklist_view.dart';
import 'package:actionnotes/ui/home_shell.dart';
import 'package:actionnotes/ui/note_blocks_editor.dart';
import 'package:actionnotes/ui/note_editor.dart';
import 'package:actionnotes/ui/note_images.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';

import 'support/fakes.dart';

/// A one-pixel PNG, so the encoder has something real to pass through.
final onePixelPng = img.encodePng(img.Image(width: 1, height: 1));

http.Client uploadingClient(List<String> written) {
  return MockClient((request) async {
    if (request.method == 'PUT') {
      written.add(Uri.decodeFull(request.url.path).split('/contents/').last);
      return stubResponse(jsonEncode({'content': {'sha': 'sha-1'}}), 200);
    }
    return stubResponse('[]', 200);
  });
}

Future<AppState> pumpList(
  WidgetTester tester,
  List<String> written, {
  bool shell = false,
}) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final store = FakeLocalStore();
  final state = AppState(
    localStore: store,
    settingsStore: FakeSettingsStore(config: testConfig),
    syncService: SyncService(
      localStore: store,
      clientFactory: (config) =>
          GitHubClient(config, client: uploadingClient(written)),
    ),
    attachmentStore: FakeAttachmentStore(),
    // Short, so the push debounce is not left pending when a test ends.
    pushDelay: const Duration(milliseconds: 20),
  );
  await state.init();
  await state.createProject('List');
  await state.addItem('list', 'An item');

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: shell ? const HomeShell() : const ChecklistView(slug: 'list'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

/// Lets every debounce in the chain fire: the note settling, then the push.
Future<void> settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

void main() {
  // The report: with a note expanded in the row, an image could not be
  // pasted, because all of the image handling lived in the other editor.
  testWidgets('an inline note can take an image', (tester) async {
    final written = <String>[];
    final state = await pumpList(tester, written);

    await tester.tap(find.byTooltip('Add notes'));
    await tester.pumpAndSettle();

    final target = tester.state<NoteImageTargetState>(
      find.byType(NoteImageTarget),
    );
    await target.upload('shot.png', onePixelPng);
    await settle(tester);

    // Uploaded to this project's attachments, and put in the note.
    expect(written, contains('attachments/list/shot.png'));
    expect(
      state.projects.single.items.single.notes,
      contains('../attachments/list/shot.png'),
    );
  });

  testWidgets('an inline note takes over paste, so a phone can use it too',
      (tester) async {
    await pumpList(tester, []);

    await tester.tap(find.byTooltip('Add notes'));
    await tester.pumpAndSettle();

    // A phone has no Ctrl+V, so the block menu's own Paste has to be the way
    // in: the editor only redirects it when a note can take an image.
    final editor = tester.widget<NoteBlocksEditor>(
      find.byType(NoteBlocksEditor),
    );
    expect(editor.onPaste, isNotNull);
    await settle(tester);
  });

  testWidgets('the full editor uses the same handling', (tester) async {
    final written = <String>[];
    final state = await pumpList(tester, written, shell: true);

    // Tapping the row opens the note in the pane on a wide window.
    await tester.tap(find.text('An item'));
    await tester.pumpAndSettle();
    expect(find.byType(NoteEditor), findsOneWidget);

    final target = tester.state<NoteImageTargetState>(
      find.byType(NoteImageTarget),
    );
    await target.upload('shot.png', onePixelPng);
    await settle(tester);

    expect(written, contains('attachments/list/shot.png'));
    expect(
      tester.widget<NoteBlocksEditor>(find.byType(NoteBlocksEditor)).onPaste,
      isNotNull,
    );
    expect(state.projects.single.items.single.notes, isNotEmpty);
  });
}
