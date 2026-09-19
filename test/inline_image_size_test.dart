import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/ui/note_blocks_editor.dart';
import 'package:actionnotes/ui/note_view.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';

import 'support/fakes.dart';

/// A picture far taller than any cap, so what the cap does to it matters.
final tallPng = img.encodePng(img.Image(width: 100, height: 1000));

Future<AppState> withTallImage() async {
  final attachments = FakeAttachmentStore();
  await attachments.save('attachments/list/tall.png', tallPng);
  final state = newTestState(FakeLocalStore(), attachments: attachments);
  await state.init();
  await state.createProject('List');
  return state;
}

/// Lets the file be found, which is real async work a widget test has to step
/// out of its fake clock for.
Future<void> settleFile(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pumpAndSettle();
}

Future<void> pumpNote(
  WidgetTester tester, {
  required double? cap,
  required AppState state,
}) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: NoteView(
            markdown: '![tall](../attachments/list/tall.png)',
            maxImageHeight: cap,
          ),
        ),
      ),
    ),
  );
  await settleFile(tester);
}

/// What the picture itself is allowed to be, as opposed to the box round it.
BoxConstraints pictureLimits(WidgetTester tester) {
  return tester
      .widget<ConstrainedBox>(
        find
            .ancestor(
              of: find.byType(Image),
              matching: find.byType(ConstrainedBox),
            )
            .first,
      )
      .constraints;
}

void main() {
  testWidgets('a cap is put on the picture, which scales it', (tester) async {
    await pumpNote(tester, cap: 340, state: await withTallImage());

    // On the picture rather than on a box around it: a markdown body hands
    // each thing in it as much height as it asks for, so a clamped box only
    // ever cut the bottom off a tall photograph.
    expect(pictureLimits(tester).maxHeight, 340);
    expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.contain);
  });

  testWidgets('with no cap the picture is left at its own size', (
    tester,
  ) async {
    await pumpNote(tester, cap: null, state: await withTallImage());

    expect(pictureLimits(tester).maxHeight, double.infinity);
  });

  testWidgets('an image being written around is capped, not clipped', (
    tester,
  ) async {
    final state = await withTallImage();
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: NoteBlocksEditor(
              initialMarkdown:
                  'Before\n\n![tall](../attachments/list/tall.png)',
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await settleFile(tester);

    // The editor still caps a tall picture, but the cap is now on the picture
    // and so scales it, instead of cutting it off at 340 pixels.
    expect(pictureLimits(tester).maxHeight, 340);
  });
}
