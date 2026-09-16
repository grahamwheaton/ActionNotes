import 'package:actionnotes/markdown/note_blocks.dart';
import 'package:actionnotes/markdown/project_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('checkboxes inside a note', () {
    test('parse as tasks, not as bullets', () {
      final blocks = NoteBlocks.parse('- [ ] open\n- [x] done');

      expect(blocks, [
        const NoteBlock.task('open'),
        const NoteBlock.task('done', done: true),
      ]);
    });

    test('write back in the same form', () {
      final markdown = NoteBlocks.serialize(const [
        NoteBlock.task('open'),
        NoteBlock.task('done', done: true),
      ]);

      expect(markdown, '- [ ] open\n- [x] done');
    });

    test('stay in the note rather than becoming project items', () {
      // This is the whole point: the project parser must read an indented
      // checkbox as note content belonging to the item above it.
      const file = '''
---
title: Bullets test
---

# Bullets test

- [ ] Real item
  - [ ] a subtask
  - [x] a done subtask
- [ ] Another real item
''';

      final project = ProjectMarkdown.parse(file, slug: 'bullets-test');

      expect(
        project.items.map((i) => i.text),
        ['Real item', 'Another real item'],
        reason: 'the subtasks belong to the first item, not the project',
      );
      expect(
        project.items.first.notes,
        '- [ ] a subtask\n- [x] a done subtask',
      );
    });

    test('a project keeps its items at the left margin on write', () {
      const file = '''
- [ ] Item
  - [ ] subtask
''';

      final once = ProjectMarkdown.serialize(
        ProjectMarkdown.parse(file, slug: 's'),
      );

      // Round-tripping must not promote the subtask or demote the item.
      final again = ProjectMarkdown.parse(once, slug: 's');
      expect(again.items, hasLength(1));
      expect(again.items.single.notes, '- [ ] subtask');
    });
  });

  group('nesting', () {
    test('two spaces is one level', () {
      final blocks = NoteBlocks.parse('- top\n  - nested\n    - deeper');

      expect(blocks.map((b) => b.indent), [0, 1, 2]);
      expect(blocks.map((b) => b.text), ['top', 'nested', 'deeper']);
    });

    test('an odd indent rounds down rather than being refused', () {
      final blocks = NoteBlocks.parse('- top\n   - three spaces');

      expect(blocks.last.indent, 1);
    });

    test('a tab counts as one level', () {
      final blocks = NoteBlocks.parse('- top\n\t- tabbed');

      expect(blocks.last.indent, 1);
    });

    test('writes the indent back out', () {
      final markdown = NoteBlocks.serialize(const [
        NoteBlock.bullet('top'),
        NoteBlock.task('nested', indent: 1),
        NoteBlock.bullet('deeper', indent: 2),
      ]);

      expect(markdown, '- top\n  - [ ] nested\n    - deeper');
    });

    test('round-trips a mixed nested list unchanged', () {
      const source = '''
- [ ] pack
  - [x] passport
  - [ ] tickets
    - check the dates
- [ ] leave''';

      final once = NoteBlocks.serialize(NoteBlocks.parse(source));

      expect(once, source);
      expect(NoteBlocks.serialize(NoteBlocks.parse(once)), source);
    });

    test('a list stays one block without blank lines between rows', () {
      // Bullets and tasks mixed still form a single list.
      final markdown = NoteBlocks.serialize(const [
        NoteBlock.bullet('one'),
        NoteBlock.task('two'),
        NoteBlock.paragraph('after'),
      ]);

      expect(markdown, '- one\n- [ ] two\n\nafter');
    });
  });

  group('typing shortcuts', () {
    test('"- [ ] " makes a checklist row', () {
      expect(
        NoteBlocks.shortcutFor(const NoteBlock.paragraph(''), '- [ ] '),
        const NoteBlock.task(''),
      );
    });

    test('"[] " makes one too, for speed', () {
      expect(
        NoteBlocks.shortcutFor(const NoteBlock.paragraph(''), '[] x'),
        const NoteBlock.task('x'),
      );
    });

    test('"- [x] " arrives already ticked', () {
      final block =
          NoteBlocks.shortcutFor(const NoteBlock.paragraph(''), '- [x] done');

      expect(block, const NoteBlock.task('done', done: true));
    });

    test('a plain dash still makes a bullet', () {
      expect(
        NoteBlocks.shortcutFor(const NoteBlock.paragraph(''), '- x'),
        const NoteBlock.bullet('x'),
      );
    });

    test('converting keeps the row at its current depth', () {
      final block = NoteBlocks.shortcutFor(
        const NoteBlock.bullet('', indent: 2),
        '[] x',
      );

      expect(block!.indent, 2);
      expect(block.type, NoteBlockType.task);
    });
  });
}
