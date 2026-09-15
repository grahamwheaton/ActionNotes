import 'package:actionnotes/markdown/project_markdown.dart';
import 'package:actionnotes/models/checklist_item.dart';
import 'package:actionnotes/models/project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parse', () {
    test('reads front matter, heading, items and notes', () {
      const source = '''
---
title: House move
created: 2026-09-15T09:12:44Z
updated: 2026-09-15T18:30:02Z
---

# House move

- [ ] Book the van
- [x] Cancel broadband

Landlord's number is in the drawer.
''';

      final project = ProjectMarkdown.parse(source, slug: 'house-move');

      expect(project.title, 'House move');
      expect(project.created, DateTime.utc(2026, 9, 15, 9, 12, 44));
      expect(project.items, [
        ChecklistItem(text: 'Book the van'),
        ChecklistItem(text: 'Cancel broadband', done: true),
      ]);
      expect(project.notes, "Landlord's number is in the drawer.");
    });

    test('falls back to the heading when front matter has no title', () {
      final project = ProjectMarkdown.parse('# Groceries\n\n- [ ] Milk\n',
          slug: 'groceries');

      expect(project.title, 'Groceries');
      expect(project.items.single.text, 'Milk');
    });

    test('falls back to the slug when there is no title at all', () {
      final project = ProjectMarkdown.parse('- [ ] Milk\n', slug: 'groceries');

      expect(project.title, 'groceries');
    });

    test('tolerates hand-edited syntax', () {
      final project = ProjectMarkdown.parse(
        '* [X] Done thing\n+ [ ] Other thing\n',
        slug: 'mixed',
      );

      expect(project.items.first.done, isTrue);
      expect(project.items.last.text, 'Other thing');
    });

    test('keeps unknown front-matter keys', () {
      final project = ProjectMarkdown.parse(
        '---\ntitle: T\ntags: home, urgent\n---\n',
        slug: 't',
      );

      expect(project.extraFrontMatter, {'tags': 'home, urgent'});
    });

    test('handles CRLF line endings', () {
      final project = ProjectMarkdown.parse(
        '---\r\ntitle: T\r\n---\r\n\r\n- [x] Item\r\n',
        slug: 't',
      );

      expect(project.title, 'T');
      expect(project.items.single, ChecklistItem(text: 'Item', done: true));
    });

    test('an empty file still yields a usable project', () {
      final project = ProjectMarkdown.parse('', slug: 'blank');

      expect(project.title, 'blank');
      expect(project.items, isEmpty);
      expect(project.notes, isEmpty);
    });
  });

  group('serialize', () {
    test('emits the canonical shape', () {
      final project = Project(
        slug: 'groceries',
        title: 'Groceries',
        items: [
          ChecklistItem(text: 'Milk'),
          ChecklistItem(text: 'Bread', done: true),
        ],
        notes: 'Shop shuts at 6.',
        created: DateTime.utc(2026, 9, 15, 9, 0, 0),
        updated: DateTime.utc(2026, 9, 15, 10, 0, 0),
      );

      expect(ProjectMarkdown.serialize(project), '''
---
title: Groceries
created: 2026-09-15T09:00:00Z
updated: 2026-09-15T10:00:00Z
---

# Groceries

- [ ] Milk
- [x] Bread

Shop shuts at 6.
''');
    });

    test('round-trips without losing anything', () {
      final original = Project(
        slug: 'trip',
        title: 'Trip',
        items: [ChecklistItem(text: 'Passport', done: true)],
        notes: 'Two lines\nof notes.',
        created: DateTime.utc(2026, 1, 2, 3, 4, 5),
        updated: DateTime.utc(2026, 1, 2, 4, 5, 6),
        extraFrontMatter: const {'tags': 'travel'},
      );

      final reparsed = ProjectMarkdown.parse(
        ProjectMarkdown.serialize(original),
        slug: 'trip',
      );

      expect(reparsed.title, original.title);
      expect(reparsed.items, original.items);
      expect(reparsed.notes, original.notes);
      expect(reparsed.created, original.created);
      expect(reparsed.updated, original.updated);
      expect(reparsed.extraFrontMatter, original.extraFrontMatter);
    });
  });

  group('slugify', () {
    test('makes filename-safe names', () {
      expect(Project.slugify('House move!'), 'house-move');
      expect(Project.slugify('  Weekly   review  '), 'weekly-review');
      expect(Project.slugify('2026 goals'), '2026-goals');
    });

    test('never returns an empty slug', () {
      expect(Project.slugify('!!!'), 'project');
    });
  });
}
