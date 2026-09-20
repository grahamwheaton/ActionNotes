import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/storage/share_code.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_github.dart';
import 'support/fakes.dart';

/// A shared notebook with one list already in it, taken on by somebody who
/// has no GitHub of their own — which is everyone but the first person.
Future<AppState> joined(
  FakeGitHub github, {
  String list = '- [ ] Milk\n',
}) async {
  github.repo('SharedProjectNotes')['projects/shopping.md'] =
      '# Shopping\n\n$list';

  final state = guestWith(github, FakeLocalStore());
  await state.init();
  await state.addSharedNotebook(ShareCode.encode(theirs));
  return state;
}

/// Long enough for a debounced push to go out.
Future<void> settleOut() =>
    Future<void>.delayed(const Duration(milliseconds: 200));

void main() {
  group('writing in a notebook that is not your own', () {
    test(
      'someone with no GitHub of their own still pushes what they write',
      () async {
        // The whole of the bug: the push was gated on your own repo being set
        // up, and somebody who pasted a code has not got one. Nothing they
        // wrote ever went out.
        final github = FakeGitHub();
        final state = await joined(github);

        await state.addItem(state.projects.single.slug, 'Bread');
        await settleOut();

        expect(
          github.repo('SharedProjectNotes')['projects/shopping.md'],
          contains('Bread'),
        );
        expect(state.projects.single.dirty, isFalse);
        state.dispose();
      },
    );

    test('ticking something off goes out too', () async {
      final github = FakeGitHub();
      final state = await joined(github);
      final slug = state.projects.single.slug;

      await state.toggleItem(slug, 0);
      await settleOut();

      expect(
        github.repo('SharedProjectNotes')['projects/shopping.md'],
        contains('- [x] Milk'),
      );
      state.dispose();
    });

    test(
      'two people writing at once keeps both, with nothing to answer',
      () async {
        final github = FakeGitHub();
        final state = await joined(github);
        final slug = state.projects.single.slug;

        // She adds something here...
        await state.addItem(slug, 'Bread');
        // ...while he adds something there, before hers has gone out.
        github.repo('SharedProjectNotes')['projects/shopping.md'] =
            '# Shopping\n\n- [ ] Milk\n- [ ] Butter\n';

        await settleOut();
        await state.sync();

        final file = github.repo('SharedProjectNotes')['projects/shopping.md']!;
        expect(file, contains('Bread'));
        expect(file, contains('Butter'));
        expect(state.projects.single.dirty, isFalse);
        state.dispose();
      },
    );
  });

  group('how often it looks', () {
    test('a notebook nobody shares is checked at the slow rate', () async {
      final state = guestWith(FakeGitHub(), FakeLocalStore());
      await state.init();

      expect(state.watchInterval, AppState.defaultSyncInterval);
      state.dispose();
    });

    test(
      'pasting a code starts it fast, without waiting to be shown',
      () async {
        // The moment somebody is standing next to the person who sent them the
        // code, trying it. Earning the fast rate first would make the one
        // check anybody actually watches the slowest.
        final github = FakeGitHub();
        final state = await joined(github);

        expect(state.watchInterval, AppState.sharedSyncInterval);
        state.dispose();
      },
    );

    test('opening the app starts it fast too', () async {
      final github = FakeGitHub();
      final state = await joined(github);

      // Quiet for long enough that it has dropped back.
      state.debugSharedQuietSince(
        DateTime.now().subtract(const Duration(minutes: 10)),
      );
      expect(state.watchInterval, AppState.defaultSyncInterval);

      // Coming back to the app is a reason to expect company.
      state.startWatching();
      expect(state.watchInterval, AppState.sharedSyncInterval);

      state.stopWatching();
      state.dispose();
    });

    test('a shared notebook that goes quiet is checked slowly again', () async {
      final github = FakeGitHub();
      final state = await joined(github);

      state.debugSharedQuietSince(
        DateTime.now().subtract(const Duration(minutes: 10)),
      );
      expect(state.watchInterval, AppState.defaultSyncInterval);

      // Until somebody writes, and then it is a conversation again.
      await state.addItem(state.projects.single.slug, 'Bread');
      expect(state.watchInterval, AppState.sharedSyncInterval);
      await settleOut();
      state.dispose();
    });

    test('a change arriving from somebody else speeds it up too', () async {
      final github = FakeGitHub();
      final state = await joined(github);
      state.debugSharedQuietSince(
        DateTime.now().subtract(const Duration(minutes: 10)),
      );
      expect(state.watchInterval, AppState.defaultSyncInterval);

      github.repo('SharedProjectNotes')['projects/shopping.md'] =
          '# Shopping\n\n- [ ] Milk\n- [ ] Butter\n';
      await state.sync();

      expect(state.watchInterval, AppState.sharedSyncInterval);
      state.dispose();
    });
  });

  group('what a check costs', () {
    test('a list that has not moved is not downloaded again', () async {
      final github = FakeGitHub();
      final state = await joined(github);

      github.reads.clear();
      await state.sync();
      await state.sync();

      // The listing says what each file's SHA is, so an unchanged one is
      // known to be unchanged without fetching it. This is what makes
      // checking every five seconds affordable on a shared token.
      expect(github.reads, isEmpty);

      github.repo('SharedProjectNotes')['projects/shopping.md'] =
          '# Shopping\n\n- [ ] Milk\n- [ ] Butter\n';
      await state.sync();

      expect(github.reads, ['projects/shopping.md']);
      state.dispose();
    });
  });
}
