import 'package:actionnotes/markdown/note_blocks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('markdown tables stay one editable block across round trips', () {
    const source = '| Name | State |\n| --- | --- |\n| One | Open |';
    final blocks = NoteBlocks.parse(source);
    expect(blocks, [const NoteBlock.table(source)]);
    expect(NoteBlocks.serialize(blocks), source);
  });

  group('parse', () {
    test('reads headings, keeping their level and dropping the hashes', () {
      final blocks = NoteBlocks.parse('# One\n\n### Three');

      expect(blocks, [
        const NoteBlock.heading('One'),
        const NoteBlock.heading('Three', level: 3),
      ]);
    });

    test('reads an image on its own line as an image block', () {
      final blocks =
          NoteBlocks.parse('![a door](../attachments/x/door.png)');

      expect(blocks, [
        const NoteBlock.image(path: '../attachments/x/door.png', alt: 'a door'),
      ]);
    });

    test('an image with text around it stays a paragraph', () {
      // Splitting it would rearrange what the person wrote.
      final blocks = NoteBlocks.parse('see ![a](b.png) here');

      expect(blocks.single.type, NoteBlockType.paragraph);
      expect(blocks.single.text, 'see ![a](b.png) here');
    });

    test('reads bullets', () {
      final blocks = NoteBlocks.parse('- one\n- two');

      expect(blocks, [
        const NoteBlock.bullet('one'),
        const NoteBlock.bullet('two'),
      ]);
    });

    test('a task line is a checklist row, not a plain bullet', () {
      final blocks = NoteBlocks.parse('- [ ] a task');

      expect(blocks.single.type, NoteBlockType.task);
      expect(blocks.single.text, 'a task');
      expect(blocks.single.done, isFalse);
    });

    test('blank lines do not become blocks', () {
      final blocks = NoteBlocks.parse('one\n\n\n\ntwo');

      expect(blocks, [
        const NoteBlock.paragraph('one'),
        const NoteBlock.paragraph('two'),
      ]);
    });

    test('a heading needs its space, as markdown requires', () {
      // '#Heading' is a paragraph everywhere else, so it is one here too.
      final blocks = NoteBlocks.parse('#Heading');

      expect(blocks.single.type, NoteBlockType.paragraph);
    });

    test('handles CRLF', () {
      final blocks = NoteBlocks.parse('# One\r\n\r\ntwo');

      expect(blocks, [
        const NoteBlock.heading('One'),
        const NoteBlock.paragraph('two'),
      ]);
    });

    test('an empty note has no blocks', () {
      expect(NoteBlocks.parse(''), isEmpty);
      expect(NoteBlocks.parse('   \n\n'), isEmpty);
    });
  });

  group('serialize', () {
    test('separates blocks with a blank line', () {
      final markdown = NoteBlocks.serialize(const [
        NoteBlock.heading('Title'),
        NoteBlock.paragraph('Some text.'),
      ]);

      expect(markdown, '# Title\n\nSome text.');
    });

    test('keeps consecutive bullets as one list', () {
      final markdown = NoteBlocks.serialize(const [
        NoteBlock.bullet('one'),
        NoteBlock.bullet('two'),
        NoteBlock.paragraph('after'),
      ]);

      expect(markdown, '- one\n- two\n\nafter');
    });

    test('writes an image reference', () {
      final markdown = NoteBlocks.serialize(const [
        NoteBlock.image(path: '../attachments/x/a.png', alt: 'a.png'),
      ]);

      expect(markdown, '![a.png](../attachments/x/a.png)');
    });

    test('drops empty blocks rather than leaving blank lines behind', () {
      final markdown = NoteBlocks.serialize(const [
        NoteBlock.paragraph('kept'),
        NoteBlock.paragraph('   '),
        NoteBlock.heading(''),
        NoteBlock.image(path: ''),
        NoteBlock.paragraph('also kept'),
      ]);

      expect(markdown, 'kept\n\nalso kept');
    });

    test('clamps a silly heading level', () {
      final markdown =
          NoteBlocks.serialize(const [NoteBlock.heading('x', level: 9)]);

      expect(markdown, '###### x');
    });
  });

  group('round trip', () {
    test('a realistic note survives unchanged', () {
      const source = '''
# A heading

Some **bold** and *italic* text.

![pasted.png](../attachments/testing/pasted.png)

- a bullet
- another bullet

Linked to [House move](house-move.md).

## Heading two

Plain closing line.''';

      final once = NoteBlocks.serialize(NoteBlocks.parse(source));
      final twice = NoteBlocks.serialize(NoteBlocks.parse(once));

      expect(once, source);
      expect(twice, source, reason: 'reopening must not drift');
    });

    test('inline markdown is left exactly alone', () {
      // The editor styles these; it must not rewrite them.
      const source = 'A `code` span, **bold**, _under_, and a\\. escape';

      expect(NoteBlocks.serialize(NoteBlocks.parse(source)), source);
    });
  });

  group('typing shortcuts', () {
    test('a hash and a space makes a heading and eats the marker', () {
      final block = NoteBlocks.shortcutFor(
        const NoteBlock.paragraph(''),
        '# My title',
      );

      expect(block, const NoteBlock.heading('My title'));
    });

    test('several hashes set the level', () {
      final block = NoteBlocks.shortcutFor(
        const NoteBlock.paragraph(''),
        '### Deep',
      );

      expect(block!.level, 3);
      expect(block.text, 'Deep');
    });

    test('a dash and a space makes a bullet', () {
      final block =
          NoteBlocks.shortcutFor(const NoteBlock.paragraph(''), '- item');

      expect(block, const NoteBlock.bullet('item'));
    });

    test('a bullet does not re-trigger on itself', () {
      expect(
        NoteBlocks.shortcutFor(const NoteBlock.bullet('x'), '- x'),
        isNull,
      );
    });

    test('ordinary text triggers nothing', () {
      expect(
        NoteBlocks.shortcutFor(const NoteBlock.paragraph(''), 'hello'),
        isNull,
      );
      expect(
        NoteBlocks.shortcutFor(const NoteBlock.paragraph(''), '#nospace'),
        isNull,
      );
    });

    test('an image block takes no shortcuts', () {
      expect(
        NoteBlocks.shortcutFor(const NoteBlock.image(path: 'a.png'), '# x'),
        isNull,
      );
    });
  });
}
