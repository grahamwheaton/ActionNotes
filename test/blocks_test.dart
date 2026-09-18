import 'package:actionnotes/markdown/project_markdown.dart';
import 'package:actionnotes/models/checklist_item.dart';
import 'package:actionnotes/models/project.dart';
import 'package:flutter_test/flutter_test.dart';

Project parse(String markdown) => ProjectMarkdown.parse(markdown, slug: 'list');

void main() {
  group('a project without headings', () {
    const plain = '''
---
title: List
created: 2026-01-01T00:00:00Z
updated: 2026-01-01T00:00:00Z
---

# List

- [ ] Buy milk
  a note
- [x] Done thing

Some trailing prose.
''';

    test('has no blocks and is unchanged by them existing', () {
      final project = parse(plain);
      expect(project.blocks, isEmpty);
      expect(project.isFlat, isTrue);
      expect(project.items.every((item) => item.block == null), isTrue);
      expect(ProjectMarkdown.serialize(project).trim(), plain.trim());
    });
  });

  group('headings become blocks', () {
    const withBlocks = '''
---
title: List
created: 2026-01-01T00:00:00Z
updated: 2026-01-01T00:00:00Z
---

# List

- [ ] Loose item

Prose before any heading.

## Shopping

- [ ] Milk
- [ ] Bread

## Thoughts

Some prose in a block.
''';

    test('items carry the heading they sit under', () {
      final project = parse(withBlocks);
      expect(project.blocks.map((b) => b.title), ['Shopping', 'Thoughts']);
      expect(project.itemsIn(null).map((i) => i.text), ['Loose item']);
      expect(project.itemsIn('Shopping').map((i) => i.text), ['Milk', 'Bread']);
      expect(project.itemsIn('Thoughts'), isEmpty);
    });

    test('prose lands in the block it is under, not the project', () {
      final project = parse(withBlocks);
      expect(project.notes, 'Prose before any heading.');
      expect(
        project.blocks.firstWhere((b) => b.title == 'Thoughts').body,
        'Some prose in a block.',
      );
      expect(
        project.blocks.firstWhere((b) => b.title == 'Shopping').body,
        isEmpty,
      );
    });

    test('round-trips exactly', () {
      expect(
        ProjectMarkdown.serialize(parse(withBlocks)).trim(),
        withBlocks.trim(),
      );
    });

    test('the flat index still addresses every item in order', () {
      final project = parse(withBlocks);
      expect(project.items.map((i) => i.text), ['Loose item', 'Milk', 'Bread']);
      expect(project.indicesIn('Shopping'), [1, 2]);
    });
  });

  group('reading what a person or a model might write', () {
    test('a heading inside an item note stays in the note', () {
      final project = parse('''
---
title: List
---

# List

- [ ] Item
  ## Not a block
  still the note
''');
      expect(project.blocks, isEmpty);
      expect(project.items.single.notes, '## Not a block\nstill the note');
    });

    test('a deeper heading is a block too, not something swallowed', () {
      final project = parse('''
---
title: List
---

# List

### Deep

- [ ] Item
''');
      expect(project.blocks.single.title, 'Deep');
      expect(project.items.single.block, 'Deep');
    });

    test('a repeated heading joins the first rather than making a twin', () {
      final project = parse('''
---
title: List
---

# List

## Shopping

- [ ] Milk

## Shopping

- [ ] Bread
''');
      expect(project.blocks.map((b) => b.title), ['Shopping']);
      expect(project.itemsIn('Shopping').map((i) => i.text), ['Milk', 'Bread']);
    });

    test('an empty block survives, so a heading typed first is not lost', () {
      final markdown = ProjectMarkdown.serialize(
        Project(
          slug: 'list',
          title: 'List',
          blocks: const [ProjectBlock(title: 'Later')],
          created: DateTime.utc(2026),
          updated: DateTime.utc(2026),
        ),
      );
      expect(markdown, contains('## Later'));
      expect(parse(markdown).blocks.single.title, 'Later');
    });

    test(
      'an item naming a block the project does not list is still written',
      () {
        final project = Project(
          slug: 'list',
          title: 'List',
          items: const [ChecklistItem(text: 'Orphan', block: 'Somewhere')],
          created: DateTime.utc(2026),
          updated: DateTime.utc(2026),
        );
        final again = parse(ProjectMarkdown.serialize(project));
        expect(again.items.single.text, 'Orphan');
        expect(again.items.single.block, 'Somewhere');
      },
    );
  });
}
