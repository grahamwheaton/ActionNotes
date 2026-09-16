import 'package:actionnotes/markdown/project_links.dart';
import 'package:actionnotes/models/project.dart';
import 'package:flutter_test/flutter_test.dart';

Project project(String slug, String title) =>
    Project(slug: slug, title: title);

final projects = [
  project('main-project', 'Main Project'),
  project('house-move', 'House move'),
];

void main() {
  group('linkTo', () {
    test('writes a portable relative markdown link', () {
      expect(
        ProjectLinks.linkTo(projects.first),
        '[Main Project](main-project.md)',
      );
    });
  });

  group('targetSlug', () {
    test('reads a bare relative link', () {
      expect(ProjectLinks.targetSlug('house-move.md'), 'house-move');
    });

    test('tolerates the prefixes other editors write', () {
      expect(ProjectLinks.targetSlug('./house-move.md'), 'house-move');
      expect(ProjectLinks.targetSlug('projects/house-move.md'), 'house-move');
      expect(ProjectLinks.targetSlug('../projects/house-move.md'), 'house-move');
      expect(ProjectLinks.targetSlug('house-move'), 'house-move');
    });

    test('ignores an anchor', () {
      expect(ProjectLinks.targetSlug('house-move.md#doors'), 'house-move');
    });

    test('is not fooled by an external link', () {
      expect(ProjectLinks.targetSlug('https://example.com/a.md'), isNull);
    });

    test('is not fooled by an attachment', () {
      expect(
        ProjectLinks.targetSlug('../attachments/house-move/door.png'),
        isNull,
      );
    });
  });

  group('normalize', () {
    test('rewrites a wikilink by title', () {
      expect(
        ProjectLinks.normalize('See [[Main Project]] for this.', projects),
        'See [Main Project](main-project.md) for this.',
      );
    });

    test('rewrites a wikilink by slug', () {
      expect(
        ProjectLinks.normalize('See [[house-move]].', projects),
        'See [House move](house-move.md).',
      );
    });

    test('matching ignores case', () {
      expect(
        ProjectLinks.normalize('[[main project]]', projects),
        '[Main Project](main-project.md)',
      );
    });

    test('keeps a custom label from the pipe form', () {
      expect(
        ProjectLinks.normalize('[[house-move|the move]]', projects),
        '[the move](house-move.md)',
      );
    });

    test('leaves an unmatched wikilink exactly as written', () {
      const notes = 'See [[Nothing Here]].';

      expect(ProjectLinks.normalize(notes, projects), notes);
    });

    test('leaves notes without wikilinks untouched', () {
      const notes = 'Plain note with a [real link](house-move.md).';

      expect(ProjectLinks.normalize(notes, projects), notes);
    });

    test('rewrites several links in one note', () {
      expect(
        ProjectLinks.normalize('[[Main Project]] and [[House move]]', projects),
        '[Main Project](main-project.md) and [House move](house-move.md)',
      );
    });

    test('does not touch an image reference', () {
      const notes = '![door](../attachments/house-move/door.png)';

      expect(ProjectLinks.normalize(notes, projects), notes);
    });
  });

  group('outgoingSlugs', () {
    test('finds markdown links and ignores attachments', () {
      const notes = '''
Linked to [House move](house-move.md) and [Main](main-project.md).
![door](../attachments/house-move/door.png)
[External](https://example.com)
''';

      final slugs = ProjectLinks.outgoingSlugs(notes);

      expect(slugs, containsAll(['house-move', 'main-project']));
      expect(slugs, hasLength(2));
    });
  });

  group('resolve', () {
    test('prefers a slug match over a title match', () {
      final ambiguous = [
        project('alpha', 'Beta'),
        project('beta', 'Gamma'),
      ];

      expect(ProjectLinks.resolve('beta', ambiguous)!.slug, 'beta');
    });

    test('returns null for an unknown target', () {
      expect(ProjectLinks.resolve('nope', projects), isNull);
    });
  });
}
