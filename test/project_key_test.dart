import 'package:actionnotes/models/notes_source.dart';
import 'package:actionnotes/models/project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('what a project is called', () {
    test('your own notes are named by their file, as they always were', () {
      final project = Project(slug: 'shopping', title: 'Shopping');

      expect(project.sourceId, NotesSource.mineId);
      expect(project.fileSlug, 'shopping');
      expect(project.path, 'projects/shopping.md');
      expect(project.isShared, isFalse);
    });

    test('a shared project carries its notebook, and the file does not', () {
      final project = Project(
        slug: Project.keyOf('shared-graham-notes', 'shopping'),
        title: 'Shopping',
        sourceId: 'shared-graham-notes',
      );

      // Unique across notebooks, because two of them can each hold a
      // shopping list and the app has to tell them apart.
      expect(project.slug, 'shared-graham-notes~shopping');
      // But the repo has never heard of the notebook, so the file is plain.
      expect(project.fileSlug, 'shopping');
      expect(project.path, 'projects/shopping.md');
      expect(project.isShared, isTrue);
    });

    test('two notebooks can hold the same file without colliding', () {
      expect(
        Project.keyOf('shared-a', 'shopping'),
        isNot(Project.keyOf('shared-b', 'shopping')),
      );
      expect(Project.keyOf(NotesSource.mineId, 'shopping'), 'shopping');
    });

    test('a slug that happens to look prefixed is still its own file', () {
      // `~` can never turn up in a slug by accident — they are letters,
      // digits and dashes — so nothing of yours is ever mistaken for a
      // shared project's name.
      final project = Project(slug: 'a~b', title: 'Odd');
      expect(project.fileSlug, 'a~b');
    });

    test('copying keeps the notebook it came from', () {
      final project = Project(
        slug: 'shared-x~list',
        title: 'List',
        sourceId: 'shared-x',
      );
      expect(project.copyWith(title: 'Other').sourceId, 'shared-x');
      expect(project.copyWith(title: 'Other').fileSlug, 'list');
    });
  });
}
