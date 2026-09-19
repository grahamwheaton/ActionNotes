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

- [ ] ⭐ Book the van
  Ring Omar, waiting on sizes.

  ![door](../attachments/house-move/door.png)
- [x] Cancel broadband

Landlord's number is in the drawer.
''';

      final project = ProjectMarkdown.parse(source, slug: 'house-move');

      expect(project.title, 'House move');
      expect(project.created, DateTime.utc(2026, 9, 15, 9, 12, 44));
      expect(project.items, [
        ChecklistItem(
          text: 'Book the van',
          starred: true,
          notes:
              'Ring Omar, waiting on sizes.\n\n'
              '![door](../attachments/house-move/door.png)',
        ),
        ChecklistItem(text: 'Cancel broadband', done: true),
      ]);
      expect(project.notes, "Landlord's number is in the drawer.");
    });

    test('falls back to the heading when front matter has no title', () {
      final project = ProjectMarkdown.parse(
        '# Groceries\n\n- [ ] Milk\n',
        slug: 'groceries',
      );

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

  group('stars', () {
    test('reads the star marker and strips it from the text', () {
      final project = ProjectMarkdown.parse(
        '- [ ] ⭐ Urgent thing\n',
        slug: 's',
      );

      expect(project.items.single.starred, isTrue);
      expect(project.items.single.text, 'Urgent thing');
    });

    test('accepts a hollow star from a hand-edited file', () {
      final project = ProjectMarkdown.parse('- [x] ★ Done thing\n', slug: 's');

      expect(project.items.single.starred, isTrue);
      expect(project.items.single.text, 'Done thing');
    });

    test('an unstarred item keeps its text intact', () {
      final project = ProjectMarkdown.parse('- [ ] Plain thing\n', slug: 's');

      expect(project.items.single.starred, isFalse);
      expect(project.items.single.text, 'Plain thing');
    });
  });

  group('item notes', () {
    test('indented lines attach to the item above them', () {
      const source = '''
- [ ] First
  A note on first.
- [ ] Second
''';

      final project = ProjectMarkdown.parse(source, slug: 'n');

      expect(project.items.first.notes, 'A note on first.');
      expect(project.items.last.notes, isEmpty);
    });

    test('a blank line inside a note block is kept', () {
      const source = '''
- [ ] Item
  Paragraph one.

  Paragraph two.
''';

      final project = ProjectMarkdown.parse(source, slug: 'n');

      expect(project.items.single.notes, 'Paragraph one.\n\nParagraph two.');
    });

    test('unindented text after a note block is the project note', () {
      const source = '''
- [ ] Item
  Item note.

Project note.
''';

      final project = ProjectMarkdown.parse(source, slug: 'n');

      expect(project.items.single.notes, 'Item note.');
      expect(project.notes, 'Project note.');
    });

    test('a note on the last item does not leak into the project note', () {
      final project = ProjectMarkdown.parse(
        '- [ ] Item\n  Trailing note.\n',
        slug: 'n',
      );

      expect(project.items.single.notes, 'Trailing note.');
      expect(project.notes, isEmpty);
    });

    test('tolerates a deeper indent and tabs', () {
      const source = '- [ ] Item\n\tTabbed note.\n    Deeper note.\n';

      final project = ProjectMarkdown.parse(source, slug: 'n');

      expect(project.items.single.notes, 'Tabbed note.\n  Deeper note.');
    });

    test('nested markdown inside a note survives', () {
      const source = '''
- [ ] Item
  - sub point one
  - sub point two
''';

      final project = ProjectMarkdown.parse(source, slug: 'n');

      // Indented list markers are note content, not items of the project.
      expect(project.items, hasLength(1));
      expect(project.items.single.notes, '- sub point one\n- sub point two');
    });
  });

  group('serialize', () {
    test('emits the canonical shape', () {
      final project = Project(
        slug: 'groceries',
        title: 'Groceries',
        items: [
          ChecklistItem(text: 'Milk', starred: true, notes: 'Semi-skimmed.'),
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

- [ ] ⭐ Milk
  Semi-skimmed.
- [x] Bread

Shop shuts at 6.
''');
    });

    test('round-trips without losing anything', () {
      final original = Project(
        slug: 'trip',
        title: 'Trip',
        items: [
          ChecklistItem(
            text: 'Passport',
            done: true,
            starred: true,
            notes: 'In the drawer.\n\n![passport](../attachments/trip/p.png)',
          ),
          ChecklistItem(text: 'Tickets'),
        ],
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

  group('a blank line between items', () {
    const source = '''
---
title: Beaverland
---

# Beaverland

- [ ] Dig the channel

- [ ] Fell the willow
  It leans over the dam.

- [x] Patch the lodge
- [ ] Count the kits

Keep the water high.
''';

    test('is remembered rather than read as an empty note', () {
      final project = ProjectMarkdown.parse(source, slug: 'beaverland');

      expect(project.items.map((item) => item.text), [
        'Dig the channel',
        'Fell the willow',
        'Patch the lodge',
        'Count the kits',
      ]);
      expect(project.items.map((item) => item.blankAfter), [
        true,
        true,
        false,
        false,
      ]);
      // The gap is a gap, not a note made of whitespace.
      expect(project.items.first.notes, '');
      expect(project.items[1].notes, 'It leans over the dam.');
    });

    test('survives a round trip, gaps and closed-up items alike', () {
      final project = ProjectMarkdown.parse(source, slug: 'beaverland');

      expect(
        ProjectMarkdown.serialize(project),
        contains('''
- [ ] Dig the channel

- [ ] Fell the willow
  It leans over the dam.

- [x] Patch the lodge
- [ ] Count the kits
'''),
      );
    });

    test('does not add one before the project notes or at the end', () {
      final project = Project(
        slug: 'beaverland',
        title: 'Beaverland',
        items: const [ChecklistItem(text: 'Count the kits')],
        notes: 'Keep the water high.',
      );

      final markdown = ProjectMarkdown.serialize(project);

      expect(
        markdown,
        contains('- [ ] Count the kits\n\nKeep the water high.'),
      );
      expect(markdown.endsWith('Keep the water high.\n'), isTrue);
    });

    test('a last item asking for a gap does not leave one dangling', () {
      final project = Project(
        slug: 'beaverland',
        title: 'Beaverland',
        items: const [ChecklistItem(text: 'Count the kits', blankAfter: true)],
      );

      final markdown = ProjectMarkdown.serialize(project);

      expect(markdown.endsWith('- [ ] Count the kits\n'), isTrue);
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
