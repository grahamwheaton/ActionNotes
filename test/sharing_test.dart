import 'package:actionnotes/models/notes_source.dart';
import 'package:actionnotes/storage/share_code.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_github.dart';
import 'support/fakes.dart';

void main() {
  group('taking on a shared notebook', () {
    test('a code adds it, and it is listed beside your own', () async {
      final github = FakeGitHub();
      final state = stateWith(github, FakeLocalStore());
      await state.init();

      final problem = await state.addSharedNotebook(ShareCode.encode(theirs));

      expect(problem, isNull);
      expect(state.sources, hasLength(2));
      expect(state.sources.first.isMine, isTrue);
      expect(state.sharedSources.single.where, 'graham/SharedProjectNotes');
      await settle(state);
    });

    test('the same code twice adds it once', () async {
      final github = FakeGitHub();
      final state = stateWith(github, FakeLocalStore());
      await state.init();

      await state.addSharedNotebook(ShareCode.encode(theirs));
      final again = await state.addSharedNotebook(ShareCode.encode(theirs));

      expect(again, 'You already have that notebook.');
      expect(state.sharedSources, hasLength(1));
      await settle(state);
    });

    test('your own notebook is not something to share with yourself', () async {
      final state = stateWith(FakeGitHub(), FakeLocalStore());
      await state.init();

      expect(
        await state.addSharedNotebook(ShareCode.encode(mine)),
        'That is your own notebook, which you already have.',
      );
      await settle(state);
    });

    test('a damaged code says so, and is not taken on', () async {
      final state = stateWith(FakeGitHub(), FakeLocalStore());
      await state.init();

      final code = ShareCode.encode(theirs);
      final problem = await state.addSharedNotebook(
        code.substring(0, code.length - 5),
      );

      expect(problem, contains('damaged'));
      expect(state.sharedSources, isEmpty);
      await settle(state);
    });

    test('something that is not a code at all says that instead', () async {
      final state = stateWith(FakeGitHub(), FakeLocalStore());
      await state.init();

      expect(
        await state.addSharedNotebook('https://github.com/graham/notes'),
        'That does not look like a share code.',
      );
      await settle(state);
    });

    test(
      'a code that cannot reach its repo is refused now, not later',
      () async {
        final github = FakeGitHub()..closed.add('SharedProjectNotes');
        final state = stateWith(github, FakeLocalStore());
        await state.init();

        // Better here than as a notebook that sits in the list never loading.
        expect(
          await state.addSharedNotebook(ShareCode.encode(theirs)),
          isNotNull,
        );
        expect(state.sharedSources, isEmpty);
        await settle(state);
      },
    );
  });

  group('two notebooks at once', () {
    test('projects from both are shown, and each keeps its own repo', () async {
      final github = FakeGitHub();
      github.repo('SharedProjectNotes')['projects/kitchen.md'] =
          '---\ntitle: Kitchen\n---\n\n# Kitchen\n\n- [ ] Tiles\n';

      final state = stateWith(github, FakeLocalStore());
      await state.init();
      await state.addSharedNotebook(ShareCode.encode(theirs));
      await state.createProject('Mine');
      await state.sync();

      final titles = state.projects.map((p) => p.title).toSet();
      expect(titles, containsAll(['Kitchen', 'Mine']));

      final kitchen = state.projects.firstWhere((p) => p.title == 'Kitchen');
      expect(kitchen.isShared, isTrue);
      // The repo has never heard of notebooks, so the file is plainly named.
      expect(kitchen.fileSlug, 'kitchen');
      expect(kitchen.path, 'projects/kitchen.md');
      await settle(state);
    });

    test('two notebooks can hold a project of the same name', () async {
      final github = FakeGitHub();
      github.repo('SharedProjectNotes')['projects/shopping.md'] =
          '---\ntitle: Shopping\n---\n\n# Shopping\n\n- [ ] Theirs\n';
      github.repo('ProjectNotes')['projects/shopping.md'] =
          '---\ntitle: Shopping\n---\n\n# Shopping\n\n- [ ] Mine\n';

      final state = stateWith(github, FakeLocalStore());
      await state.init();
      await state.addSharedNotebook(ShareCode.encode(theirs));
      await state.sync();

      final both = state.projects.where((p) => p.title == 'Shopping');
      expect(both, hasLength(2));
      // Told apart by the notebook, without either file being renamed.
      expect(both.map((p) => p.slug).toSet(), hasLength(2));
      expect(both.map((p) => p.fileSlug).toSet(), {'shopping'});
      await settle(state);
    });

    test('a shared notebook that fails does not take your own down', () async {
      final github = FakeGitHub();
      final state = stateWith(github, FakeLocalStore());
      await state.init();
      await state.addSharedNotebook(ShareCode.encode(theirs));

      await state.createProject('Mine');
      github.closed.add('SharedProjectNotes');
      await state.sync();

      // Said out loud, and named, so it is clear which notebook is unwell.
      expect(state.message, contains('SharedProjectNotes'));
      // And your own notes are still here and still pushed.
      expect(state.projects.any((p) => p.title == 'Mine'), isTrue);
      expect(
        github.repo('ProjectNotes').containsKey('projects/mine.md'),
        isTrue,
      );
      await settle(state);
    });
  });

  group('sharing a project', () {
    test('moves the file into the other notebook', () async {
      final github = FakeGitHub();
      final state = stateWith(github, FakeLocalStore());
      await state.init();
      await state.addSharedNotebook(ShareCode.encode(theirs));

      final project = await state.createProject('Kitchen');
      await state.addItem(project.slug, 'Tiles');
      await state.sync();
      expect(
        github.repo('ProjectNotes').containsKey('projects/kitchen.md'),
        isTrue,
      );

      final problem = await state.moveProject(
        project.slug,
        state.sharedSources.single.id,
      );
      expect(problem, isNull);
      await state.sync();

      // One copy, in the shared repo, and gone from the private one: two
      // copies of a list drift apart within a day.
      expect(
        github.repo('SharedProjectNotes').containsKey('projects/kitchen.md'),
        isTrue,
      );
      expect(
        github.repo('ProjectNotes').containsKey('projects/kitchen.md'),
        isFalse,
      );

      final moved = state.projects.firstWhere((p) => p.title == 'Kitchen');
      expect(moved.isShared, isTrue);
      expect(moved.items.single.text, 'Tiles');
      await settle(state);
    });

    test('and can be brought back again', () async {
      final github = FakeGitHub();
      final state = stateWith(github, FakeLocalStore());
      await state.init();
      await state.addSharedNotebook(ShareCode.encode(theirs));

      final project = await state.createProject('Kitchen');
      final sharedId = state.sharedSources.single.id;
      await state.moveProject(project.slug, sharedId);

      final shared = state.projects.firstWhere((p) => p.title == 'Kitchen');
      expect(await state.moveProject(shared.slug, NotesSource.mineId), isNull);

      expect(
        state.projects.firstWhere((p) => p.title == 'Kitchen').isShared,
        isFalse,
      );
      await settle(state);
    });

    test('a name already taken in the other notebook is kept apart', () async {
      final github = FakeGitHub();
      github.repo('SharedProjectNotes')['projects/kitchen.md'] =
          '---\ntitle: Kitchen\n---\n\n# Kitchen\n\n- [ ] Theirs\n';

      final state = stateWith(github, FakeLocalStore());
      await state.init();
      await state.addSharedNotebook(ShareCode.encode(theirs));
      await state.sync();

      final project = await state.createProject('Kitchen');
      await state.moveProject(project.slug, state.sharedSources.single.id);

      final there = state.projects.where((p) => p.isShared).toList();
      expect(there, hasLength(2));
      // The one arriving is given a name of its own rather than writing over
      // the one that was already there.
      expect(there.map((p) => p.fileSlug).toSet(), {'kitchen', 'kitchen-2'});
      await settle(state);
    });

    test('moving somewhere that is not a notebook says so', () async {
      final state = stateWith(FakeGitHub(), FakeLocalStore());
      await state.init();
      final project = await state.createProject('Kitchen');

      expect(
        await state.moveProject(project.slug, 'shared-nowhere'),
        'That notebook is no longer here.',
      );
      await settle(state);
    });
  });

  group('giving a notebook up', () {
    test(
      'takes its projects and its token, and leaves the repo alone',
      () async {
        final github = FakeGitHub();
        github.repo('SharedProjectNotes')['projects/kitchen.md'] =
            '---\ntitle: Kitchen\n---\n\n# Kitchen\n';

        final store = FakeLocalStore();
        final state = stateWith(github, store);
        await state.init();
        await state.addSharedNotebook(ShareCode.encode(theirs));
        await state.sync();
        expect(state.projects.any((p) => p.title == 'Kitchen'), isTrue);

        final id = state.sharedSources.single.id;
        await state.forgetSharedNotebook(id);

        expect(state.sharedSources, isEmpty);
        expect(state.projects.any((p) => p.title == 'Kitchen'), isFalse);
        expect(store.savedBySource.containsKey(id), isFalse);
        // This device letting go, not a deletion: what is in the repo stays.
        expect(
          github.repo('SharedProjectNotes').containsKey('projects/kitchen.md'),
          isTrue,
        );
        await settle(state);
      },
    );

    test('your own notebook cannot be given up', () async {
      final state = stateWith(FakeGitHub(), FakeLocalStore());
      await state.init();

      await state.forgetSharedNotebook(NotesSource.mineId);
      expect(state.sources.any((s) => s.isMine), isTrue);
      await settle(state);
    });
  });

  group('the code to hand someone', () {
    test('a shared notebook has one, and it reads back as that repo', () async {
      final state = stateWith(FakeGitHub(), FakeLocalStore());
      await state.init();
      await state.addSharedNotebook(ShareCode.encode(theirs));

      final code = state.shareCodeFor(state.sharedSources.single.id);
      expect(code, isNotNull);
      expect(ShareCode.decode(code!)!.repo, 'SharedProjectNotes');
      await settle(state);
    });

    test('your own has none: its token reaches everything you have', () async {
      final state = stateWith(FakeGitHub(), FakeLocalStore());
      await state.init();

      expect(state.shareCodeFor(NotesSource.mineId), isNull);
      await settle(state);
    });
  });
}
