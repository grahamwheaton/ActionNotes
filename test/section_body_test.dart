import 'package:actionnotes/markdown/project_markdown.dart';
import 'package:actionnotes/models/checklist_item.dart';
import 'package:actionnotes/models/project.dart';
import 'package:flutter_test/flutter_test.dart';

Project parse(String markdown) => ProjectMarkdown.parse(markdown, slug: 'list');

void main() {
  group('a checklist typed into a section note', () {
    final project = Project(
      slug: 'list',
      title: 'List',
      created: DateTime.utc(2026),
      updated: DateTime.utc(2026),
      blocks: const [
        ProjectBlock(
          title: 'Long note',
          body: 'Some text goes here\n\n- [ ] A checkable task\n- [ ] One more',
        ),
      ],
      items: const [ChecklistItem(text: 'A real item', block: 'Long note')],
    );

    test('stays in the note rather than becoming items of the section', () {
      final again = parse(ProjectMarkdown.serialize(project));

      // One item, not three: the checklist in the prose is prose.
      expect(again.items.map((i) => i.text), ['A real item']);
      expect(again.blocks.single.body, contains('- [ ] A checkable task'));
      expect(again.blocks.single.body, contains('Some text goes here'));
    });

    test('survives being written and read back twice', () {
      final once = parse(ProjectMarkdown.serialize(project));
      final twice = parse(ProjectMarkdown.serialize(once));
      expect(ProjectMarkdown.serialize(twice), ProjectMarkdown.serialize(once));
      expect(twice.items.length, 1);
      expect(twice.blocks.single.body, once.blocks.single.body);
    });

    test('the prose is written above the items, where it cannot be read as '
        'the last one\'s notes', () {
      final markdown = ProjectMarkdown.serialize(project);
      expect(
        markdown.indexOf('Some text goes here'),
        lessThan(markdown.indexOf('- [ ] A real item')),
      );
    });

    test('an item keeps its own notes alongside a section that has prose', () {
      final withNotes = project.copyWith(
        items: const [
          ChecklistItem(
            text: 'A real item',
            block: 'Long note',
            notes: 'belongs to the item',
          ),
        ],
      );
      final again = parse(ProjectMarkdown.serialize(withNotes));
      expect(again.items.single.notes, 'belongs to the item');
      expect(again.blocks.single.body, contains('Some text goes here'));
    });
  });

  group('reading stays forgiving', () {
    test(
      'an unindented list under a heading is still that section\'s items',
      () {
        final project = parse('''
---
title: List
---

# List

## Shopping

- [ ] Milk
- [ ] Bread
''');
        expect(project.itemsIn('Shopping').map((i) => i.text), [
          'Milk',
          'Bread',
        ]);
      },
    );

    test('unindented prose typed on GitHub is still the body', () {
      final project = parse('''
---
title: List
---

# List

## Thoughts

Written by hand, not indented.
''');
      expect(project.blocks.single.body, 'Written by hand, not indented.');
    });

    test('an indented list under a heading is the body', () {
      final project = parse('''
---
title: List
---

# List

## Thoughts

  Some prose.

  - [ ] and a list inside it
''');
      expect(project.items, isEmpty);
      expect(
        project.blocks.single.body,
        contains('- [ ] and a list inside it'),
      );
    });
  });
}
