import 'package:actionnotes/models/sidebar_layout.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_github.dart';
import 'support/fakes.dart';

void main() {
  group('the arrangement itself', () {
    const layout = SidebarLayout(
      groups: [
        ProjectGroup(name: 'Work', colour: 'blue', slugs: ['quote', 'invoice']),
        ProjectGroup(name: 'Home', slugs: ['shopping']),
      ],
      loose: ['ideas'],
    );

    test('reads back exactly as it was written', () {
      final again = SidebarLayout.parse(layout.serialize());

      expect(again.loose, ['ideas']);
      expect(again.groups.map((g) => g.name), ['Work', 'Home']);
      expect(again.groups.first.colour, 'blue');
      expect(again.groups.first.slugs, ['quote', 'invoice']);
    });

    test('a file edited into nonsense is no arrangement, not an error', () {
      // Everything loose in the order it comes, which is what it was before
      // there was an arrangement at all.
      expect(SidebarLayout.parse('not json').isEmpty, isTrue);
      expect(SidebarLayout.parse('[]').isEmpty, isTrue);
      expect(SidebarLayout.parse('{"groups":[{}]}').groups, isEmpty);
    });

    test('reordering within one group preserves the intended drop position', () {
      const arranged = SidebarLayout(groups: [
        ProjectGroup(name: 'Work', slugs: ['a', 'b', 'c']),
      ]);
      expect(arranged.place('a', group: 'Work', at: 3).groups.single.slugs,
          ['b', 'c', 'a']);
      expect(arranged.place('c', group: 'Work', at: 1).groups.single.slugs,
          ['a', 'c', 'b']);
    });

    test('a project can only be in one place at a time', () {
      final moved = layout.place('quote', group: 'Home', at: 0);

      expect(moved.groupOf('quote')!.name, 'Home');
      expect(moved.groups.first.slugs, ['invoice']);
      expect(moved.groups.last.slugs, ['quote', 'shopping']);
    });

    test('moving one out of a group leaves it loose', () {
      final out = layout.place('shopping');

      expect(out.groupOf('shopping'), isNull);
      expect(out.loose, ['ideas', 'shopping']);
    });

    test('putting a group away keeps what was in it', () {
      // A group is a way of looking at a list. Losing somebody's projects
      // because they tidied a heading away would be unforgivable.
      final gone = layout.withoutGroup('Work');

      expect(gone.groups.map((g) => g.name), ['Home']);
      expect(gone.loose, containsAll(['quote', 'invoice']));
    });

    test('a project that no longer exists is dropped', () {
      final pruned = layout.prunedTo({'quote', 'ideas'});

      expect(pruned.known, {'quote', 'ideas'});
    });
  });

  group('arranging the list', () {
    test('a new project is at the end rather than nowhere', () async {
      final state = stateWith(FakeGitHub(), FakeLocalStore());
      await state.init();
      await state.createProject('Alpha');
      await state.createProject('Beta');

      // Nothing has been arranged, so the order is whatever it was.
      expect(state.looseProjects.map((p) => p.title), ['Alpha', 'Beta']);

      await state.placeProject('beta', at: 0);
      expect(state.looseProjects.map((p) => p.title), ['Beta', 'Alpha']);

      // And one made afterwards is still visible, at the end.
      await state.createProject('Gamma');
      expect(state.looseProjects.map((p) => p.title), [
        'Beta',
        'Alpha',
        'Gamma',
      ]);
      state.dispose();
    });

    test('a group holds what is put in it, in order', () async {
      final state = stateWith(FakeGitHub(), FakeLocalStore());
      await state.init();
      await state.createProject('Quote');
      await state.createProject('Invoice');

      expect(await state.addGroup('Work', colour: 'blue'), isTrue);
      await state.placeProject('quote', group: 'Work');
      await state.placeProject('invoice', group: 'Work', at: 0);

      final group = state.sidebar.groups.single;
      expect(state.projectsIn(group).map((p) => p.title), ['Invoice', 'Quote']);
      expect(state.looseProjects, isEmpty);
      expect(state.groupOf('quote')!.name, 'Work');
      state.dispose();
    });

    test('two groups cannot share a name', () async {
      final state = stateWith(FakeGitHub(), FakeLocalStore());
      await state.init();

      expect(await state.addGroup('Work'), isTrue);
      expect(await state.addGroup('Work'), isFalse);
      expect(await state.addGroup('  '), isFalse);
      expect(state.sidebar.groups, hasLength(1));
      state.dispose();
    });
  });

  group('the arrangement across your devices', () {
    test('one made on the phone is what the desktop opens with', () async {
      final github = FakeGitHub();
      github.repo('ProjectNotes')['projects/quote.md'] = '# Quote\n';

      final phone = stateWith(github, FakeLocalStore());
      await phone.init();
      await phone.sync();
      await phone.addGroup('Work', colour: 'blue');
      await phone.placeProject('quote', group: 'Work');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final desktop = stateWith(github, FakeLocalStore());
      await desktop.init();
      await desktop.sync();

      expect(desktop.sidebar.groups.single.name, 'Work');
      expect(desktop.groupOf('quote')!.name, 'Work');
      phone.dispose();
      desktop.dispose();
    });
  });
}
