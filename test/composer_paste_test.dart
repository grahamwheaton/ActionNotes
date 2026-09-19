import 'dart:convert';

import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/storage/github_client.dart';
import 'package:actionnotes/storage/sync_service.dart';
import 'package:actionnotes/ui/checklist_view.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';

import 'support/fakes.dart';

final Uint8List onePixelPng = img.encodePng(img.Image(width: 1, height: 1));

/// Stands in for both clipboards a paste can come from: the platform's
/// picture one, and the ordinary text one.
void installClipboard(WidgetTester tester, {Uint8List? image, String? text}) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('pasteboard'),
    (call) async => call.method == 'image' ? image : null,
  );
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async =>
        call.method == 'Clipboard.getData' ? {'text': text ?? ''} : null,
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('pasteboard'),
      null,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });
}

Future<AppState> pumpList(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // Attaching uploads, so it needs a repo configured and something at the
  // other end of the wire, the way it does in the app.
  final store = FakeLocalStore();
  final state = AppState(
    localStore: store,
    settingsStore: FakeSettingsStore(config: testConfig),
    syncService: SyncService(
      localStore: store,
      clientFactory: (config) => GitHubClient(
        config,
        client: MockClient((request) async {
          if (request.method == 'PUT') {
            return stubResponse(
              jsonEncode({
                'content': {'sha': 'sha-1'},
              }),
              200,
            );
          }
          return stubResponse('[]', 200);
        }),
      ),
    ),
    attachmentStore: FakeAttachmentStore(),
    pushDelay: const Duration(milliseconds: 20),
  );
  await state.init();
  await state.createProject('List');

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

Future<void> pressPaste(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a picture pasted while writing a task becomes its notes', (
    tester,
  ) async {
    final state = await pumpList(tester);
    installClipboard(tester, image: onePixelPng);

    await tester.enterText(find.byType(TextField).last, 'Fix the door');
    await tester.pumpAndSettle();
    await pressPaste(tester);

    final item = state.projects.single.items.single;
    expect(item.text, 'Fix the door');
    // In the item's notes, not stuck on the end of its title.
    expect(item.notes, contains('!['));
    expect(item.notes, contains('attachments/list/'));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('with nothing written the item is still named something', (
    tester,
  ) async {
    final state = await pumpList(tester);
    installClipboard(tester, image: onePixelPng);

    await tester.tap(find.byType(TextField).last);
    await tester.pumpAndSettle();
    await pressPaste(tester);

    expect(state.projects.single.items.single.text, 'Photo');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('with no picture on the clipboard the text is pasted as usual', (
    tester,
  ) async {
    final state = await pumpList(tester);
    installClipboard(tester, text: 'from the clipboard');

    await tester.enterText(find.byType(TextField).last, 'Ring ');
    await tester.pumpAndSettle();
    await pressPaste(tester);

    // Intercepting the key means owning both halves of what it does.
    expect(find.text('Ring from the clipboard'), findsOneWidget);
    expect(state.projects.single.items, isEmpty);
    await tester.pump(const Duration(seconds: 3));
  });
}
