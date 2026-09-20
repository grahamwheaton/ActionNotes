import 'dart:convert';

import 'package:actionnotes/ui/note_view.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:actionnotes/storage/share_code.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_github.dart';
import 'support/fakes.dart';

/// An arrangement as the desktop would have written it: one section named a
/// canvas, with a card placed in it.
String layoutJson() => jsonEncode({
  'version': 1,
  'sections': {
    'Board': [
      {'ref': '../attachments/holiday/beach.png', 'x': 40.0, 'y': 60.0},
    ],
  },
});

void main() {
  group('a canvas made on one machine', () {
    test('arrives as a canvas on the other, not a bullet list', () async {
      // The desktop made it: the section's markdown and, beside it, the
      // arrangement that makes the section a canvas rather than a list.
      final github = FakeGitHub();
      github.repo('ProjectNotes')['projects/holiday.md'] =
          '# Holiday\n\n## Board\n\n'
          '- ![beach.png](../attachments/holiday/beach.png)\n';
      github.repo('ProjectNotes')['canvas/holiday.json'] = layoutJson();

      // The phone: nothing local at all, just a sync.
      final phone = stateWith(github, FakeLocalStore());
      await phone.init();
      await phone.sync();

      final project = phone.projects.single;
      expect(project.blocks.single.title, 'Board');
      expect(
        phone.isCanvas(project.slug, 'Board'),
        isTrue,
        reason: 'the arrangement beside the file is what makes it a canvas',
      );
      phone.dispose();
    });

    test('an arrangement that has not moved is not fetched again', () async {
      final github = FakeGitHub();
      github.repo('ProjectNotes')['projects/holiday.md'] =
          '# Holiday\n\n## Board\n\n- A note\n';
      github.repo('ProjectNotes')['canvas/holiday.json'] = layoutJson();

      final state = stateWith(github, FakeLocalStore());
      await state.init();
      await state.sync();

      github.reads.clear();
      await state.sync();

      expect(github.reads, isEmpty);
      state.dispose();
    });

    test('a project with no canvas costs nothing extra', () async {
      final github = FakeGitHub();
      github.repo('ProjectNotes')['projects/list.md'] =
          '# List\n\n- [ ] Milk\n';

      final state = stateWith(github, FakeLocalStore());
      await state.init();
      await state.sync();

      expect(state.isCanvas(state.projects.single.slug, 'Board'), isFalse);
      state.dispose();
    });
  });

  group('a picture in a shared list', () {
    test('is fetched from the notebook it is in, not from your own', () async {
      // The bug: every picture was fetched against your own repo, whatever
      // notebook the list was in. So nobody but the uploader could see a
      // picture in a shared list — and somebody who joined with a code, with
      // no repo of their own, could never see one at all.
      final github = FakeGitHub();
      github.repo('SharedProjectNotes')['projects/holiday.md'] =
          '# Holiday\n\n- Look at this\n';

      final attachments = FakeAttachmentStore();
      attachments.remote['SharedProjectNotes'] = {
        'attachments/holiday/beach.png': 'the picture'.codeUnits,
      };

      final state = guestWith(
        github,
        FakeLocalStore(),
        attachments: attachments,
      );
      await state.init();
      await state.addSharedNotebook(ShareCode.encode(theirs));

      final file = await state.attachmentFor(
        '../attachments/holiday/beach.png',
      );

      expect(file, isNotNull);
      expect(await file!.readAsString(), 'the picture');
      // Asked the notebook the list is in. Asking your own — which is what
      // it used to do — would have found nothing, and for somebody who
      // joined with a code there is no "own" to ask.
      expect(attachments.askedWith.single.repo, 'SharedProjectNotes');
      state.dispose();
    });

    test('a picture already on the device needs no notebook at all', () async {
      final github = FakeGitHub();
      final attachments = FakeAttachmentStore();
      await attachments.save(
        'attachments/holiday/beach.png',
        'cached'.codeUnits,
      );

      final state = guestWith(
        github,
        FakeLocalStore(),
        attachments: attachments,
      );
      await state.init();

      final file = await state.attachmentFor(
        '../attachments/holiday/beach.png',
      );

      expect(await file!.readAsString(), 'cached');
      state.dispose();
    });

    test('something that is not an attachment is not fetched', () async {
      final state = guestWith(FakeGitHub(), FakeLocalStore());
      await state.init();

      expect(await state.attachmentFor('https://example.com/a.png'), isNull);
      state.dispose();
    });
  });

  group('a picture that was not there yet', () {
    testWidgets('appears once a sync brings it, without a restart', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final github = FakeGitHub();
      github.repo('ProjectNotes')['projects/holiday.md'] =
          '# Holiday\n\n- [ ] Look\n';

      final attachments = FakeAttachmentStore();
      final state = stateWith(
        github,
        FakeLocalStore(),
        attachments: attachments,
      );
      await state.init();
      await state.sync();

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(
              body: NoteView(
                markdown: '![beach.png](../attachments/holiday/beach.png)',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Nothing to fetch yet: the other device has not finished uploading.
      expect(find.byType(Image), findsNothing);
      final firstTries = attachments.askedWith.length;
      expect(firstTries, greaterThan(0));

      // A rebuild that is not a sync must not ask again, or a project of
      // thirty pictures would ask GitHub for all thirty on every keystroke.
      await tester.pump();
      expect(attachments.askedWith.length, firstTries);

      // Now the picture lands, and a sync brings the news.
      attachments.remote['ProjectNotes'] = {
        'attachments/holiday/beach.png': 'the picture'.codeUnits,
      };
      await state.sync();
      await tester.pumpAndSettle();

      expect(
        find.byType(Image),
        findsOneWidget,
        reason: 'it should not take quitting the app to see it',
      );
      await tester.pump(const Duration(seconds: 3));
    });
  });
}
