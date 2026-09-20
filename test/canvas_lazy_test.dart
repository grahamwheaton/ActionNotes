import 'package:actionnotes/models/canvas_layout.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/checklist_view.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:actionnotes/ui/touch_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_github.dart';
import 'support/fakes.dart';

/// Two pictures: one where the board opens, one a long way off to the side.
const near = '../attachments/board/near.png';
const far = '../attachments/board/far.png';

Future<AppState> pumpBoard(
  WidgetTester tester,
  FakeAttachmentStore attachments,
) async {
  TouchInput.debugOverride = false;
  addTearDown(() => TouchInput.debugOverride = null);

  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final github = FakeGitHub();
  github.repo('ProjectNotes')['projects/board.md'] = '# Board\n';
  attachments.remote['ProjectNotes'] = {
    'attachments/board/near.png': 'near'.codeUnits,
    'attachments/board/far.png': 'far'.codeUnits,
  };

  final state = stateWith(github, FakeLocalStore(), attachments: attachments);
  await state.init();
  await state.createProject('Board');
  await state.addBlock('board', 'Board');
  await state.setBlockBody(
    'board',
    'Board',
    '- ![near](../attachments/board/near.png)\n'
        '- ![far](../attachments/board/far.png)',
  );
  await state.setCanvas('board', 'Board', true);
  await state.setCanvasSpots('board', 'Board', const [
    CanvasSpot(x: 20, y: 20, width: 160, ref: near),
    // Far off to the right: several screens away at this zoom.
    CanvasSpot(x: 6000, y: 20, width: 160, ref: far),
  ]);

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const ChecklistView(slug: 'board'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

void main() {
  testWidgets('a picture off the side of the board is not fetched yet', (
    tester,
  ) async {
    final attachments = FakeAttachmentStore();
    await pumpBoard(tester, attachments);

    // A board of thirty pictures fetched all thirty the moment it opened,
    // most of them for nothing.
    expect(attachments.saved.keys, contains('attachments/board/near.png'));
    expect(
      attachments.saved.keys,
      isNot(contains('attachments/board/far.png')),
    );
    await tester.pump(const Duration(seconds: 3));
  });
}
