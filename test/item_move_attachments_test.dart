import 'package:actionnotes/storage/share_code.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_github.dart';
import 'support/fakes.dart';

void main() {
  for (final stale in [false, true]) {
    test('shared item attachment round trip; stale link: $stale', () async {
      final github = FakeGitHub();
      final attachments = FakeAttachmentStore();
      github.repo('SharedProjectNotes')['projects/rupertunlocks.md'] =
          '---\ntitle: Rupert Unlocks\n---\n\n# Rupert Unlocks\n\n'
          '- [ ] SnowRunner\n'
          '  ![Screenshot](../attachments/rupertunlocks/screenshot.png)\n\n'
          '  £10.49\n';
      attachments.remote['SharedProjectNotes'] = {
        'attachments/rupertunlocks/screenshot.png': [65, 66, 67],
      };
      final state = stateWith(github, FakeLocalStore(),
          attachments: attachments);
      await state.init();
      await state.addSharedNotebook(ShareCode.encode(theirs));
      await state.sync();
      final daily = await state.createProject('Daily note');
      final shared = state.projects.firstWhere((p) => p.title == 'Rupert Unlocks');
      expect(shared.slug, isNot(shared.fileSlug));

      expect(await state.moveItem(shared.slug, 0, daily.slug), isNull);
      expect(state.projectBySlug(daily.slug)!.items.single.notes,
          contains('../attachments/daily-note/screenshot.png'));
      expect(attachments.saved['attachments/daily-note/screenshot.png'],
          [65, 66, 67]);

      if (stale) {
        // Reproduce files written by the old move code: the copy exists in
        // Daily Notes, but its markdown still names the original folder.
        await state.setItemNotes(daily.slug, 0,
            '![Screenshot](../attachments/rupertunlocks/screenshot.png)\n\n£10.49');
      }

      expect(await state.moveItem(daily.slug, 0, shared.slug), isNull);
      final returned = state.projectBySlug(shared.slug)!.items.single;
      expect(returned.text, 'SnowRunner');
      expect(returned.notes,
          contains('../attachments/rupertunlocks/screenshot.png'));
      expect(returned.notes, contains('£10.49'));
      expect(returned.notes, isNot(contains(shared.slug)));
      expect(state.projectBySlug(daily.slug)!.items, isEmpty);
      await settle(state);
    });
  }

  test('missing attachment leaves both item lists unchanged', () async {
    final state = stateWith(FakeGitHub(), FakeLocalStore(),
        attachments: FakeAttachmentStore());
    await state.init();
    final from = await state.createProject('From');
    final to = await state.createProject('To');
    await state.addItem(from.slug, 'Keep me');
    await state.setItemNotes(from.slug, 0,
        '![Missing](../attachments/from/missing.png)');
    expect(await state.moveItem(from.slug, 0, to.slug), isNotNull);
    expect(state.projectBySlug(from.slug)!.items.single.text, 'Keep me');
    expect(state.projectBySlug(to.slug)!.items, isEmpty);
    await settle(state);
  });
}
