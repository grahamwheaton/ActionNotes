import 'package:actionnotes/models/notes_source.dart';
import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/storage/notebook_index.dart';
import 'package:actionnotes/storage/share_code.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_github.dart';
import 'support/fakes.dart';

/// Your own repo, on a device signed in to it.
AppState yours(FakeGitHub github, FakeLocalStore store) =>
    stateWith(github, store);

Future<void> settleOut() =>
    Future<void>.delayed(const Duration(milliseconds: 200));

void main() {
  group('the list of notebooks your own repo keeps', () {
    test('reads back what it wrote', () {
      final index = NotebookIndex.of([
        NotesSource.sharedFrom(theirs, label: 'Kitchen'),
      ]);

      final read = NotebookIndex.parse(index.serialize());

      expect(read.entries.single.label, 'Kitchen');
      expect(read.sources.single.where, 'graham/SharedProjectNotes');
    });

    test('a file edited into nonsense is empty, not an error', () {
      expect(NotebookIndex.parse('not json at all').isEmpty, isTrue);
      expect(NotebookIndex.parse('{"a":1}').isEmpty, isTrue);
      // An entry without a code is no use, and does not take the rest down.
      expect(NotebookIndex.parse('[{"label":"Kitchen"}]').isEmpty, isTrue);
    });
  });

  group('a notebook added on one device', () {
    test('turns up on another signed in to the same repo', () async {
      final github = FakeGitHub();
      github.repo('SharedProjectNotes')['projects/shopping.md'] =
          '# Shopping\n\n- [ ] Milk\n';

      // The phone: adds the notebook, which writes it into your own repo.
      final phone = yours(github, FakeLocalStore());
      await phone.init();
      await phone.addSharedNotebook(ShareCode.encode(theirs), label: 'Kitchen');
      await phone.sync();

      expect(github.repo('ProjectNotes')[NotebookIndex.path], isNotNull);

      // The desktop: a different device, its own local storage, nothing
      // pasted into it. It is signed in to your repo and that is all.
      final desktop = yours(github, FakeLocalStore());
      await desktop.init();
      await desktop.sync();

      expect(desktop.sharedSources.single.where, 'graham/SharedProjectNotes');
      expect(
        desktop.projects.map((p) => p.title),
        contains('Shopping'),
        reason: 'the list itself should arrive, not just its notebook',
      );
      phone.dispose();
      desktop.dispose();
    });

    test('given up on one device, it goes from the other too', () async {
      final github = FakeGitHub();
      final phone = yours(github, FakeLocalStore());
      await phone.init();
      await phone.addSharedNotebook(ShareCode.encode(theirs));
      await phone.sync();

      await phone.forgetSharedNotebook(phone.sharedSources.single.id);

      final desktop = yours(github, FakeLocalStore());
      await desktop.init();
      await desktop.sync();

      // And crucially it does not come back on the phone's next sync either,
      // which would be indistinguishable from a bug.
      await phone.sync();

      expect(desktop.sharedSources, isEmpty);
      expect(phone.sharedSources, isEmpty);
      phone.dispose();
      desktop.dispose();
    });

    test('a public repo is never written a code, and says why', () async {
      final github = FakeGitHub();
      github.public.add('ProjectNotes');

      final state = yours(github, FakeLocalStore());
      await state.init();
      await state.addSharedNotebook(ShareCode.encode(theirs));
      await state.sync();

      // The code carries a token. A public repo would publish it, and that
      // cannot be taken back once something has crawled it.
      expect(github.repo('ProjectNotes')[NotebookIndex.path], isNull);
      expect(state.message, contains('public'));
      // The notebook still works here; only the convenience is off.
      expect(state.sharedSources, hasLength(1));
      state.dispose();
    });
  });

  group('a project that has gone from the repo', () {
    test('goes from this device too, rather than haunting it', () async {
      final github = FakeGitHub();
      github.repo('ProjectNotes')['projects/shopping.md'] =
          '# Shopping\n\n- [ ] Milk\n';

      final state = yours(github, FakeLocalStore());
      await state.init();
      await state.sync();
      expect(state.projects.map((p) => p.title), ['Shopping']);

      // Moved into a shared notebook from another device, so it is no longer
      // in this repo at all.
      github.repo('ProjectNotes').remove('projects/shopping.md');
      await state.sync();

      expect(state.projects, isEmpty);
      state.dispose();
    });

    test(
      'one made here and not yet pushed is not mistaken for a deletion',
      () async {
        final github = FakeGitHub();
        final state = yours(github, FakeLocalStore());
        await state.init();

        await state.createProject('Brand new');
        // Synced before the debounced push has gone out: it has never been in
        // a listing, and dropping it would delete somebody's work for being
        // new.
        await state.sync();

        expect(state.projects.map((p) => p.title), ['Brand new']);
        await settleOut();
        state.dispose();
      },
    );
  });
}
