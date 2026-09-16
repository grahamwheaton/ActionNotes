import 'package:actionnotes/markdown/note_blocks.dart';
import 'package:actionnotes/ui/block_type_menu.dart';
import 'package:actionnotes/ui/inline_format.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

TextEditingValue valueOf(String text, {int? start, int? end}) {
  return TextEditingValue(
    text: text,
    selection: TextSelection(
      baseOffset: start ?? 0,
      extentOffset: end ?? text.length,
    ),
  );
}

void main() {
  group('toggle', () {
    test('wraps a selection', () {
      final result = InlineFormat.toggle(
        valueOf('hello world', start: 6, end: 11),
        InlineMark.bold,
      );

      expect(result.text, 'hello **world**');
      // The word stays selected, so a second press undoes it.
      expect(result.selection.start, 8);
      expect(result.selection.end, 13);
    });

    test('a second press unwraps it', () {
      final wrapped = InlineFormat.toggle(
        valueOf('hello world', start: 6, end: 11),
        InlineMark.bold,
      );
      final result = InlineFormat.toggle(wrapped, InlineMark.bold);

      expect(result.text, 'hello world');
      expect(result.selection.start, 6);
      expect(result.selection.end, 11);
    });

    test('unwraps when the markers sit inside the selection', () {
      final result = InlineFormat.toggle(
        valueOf('**bold**'),
        InlineMark.bold,
      );

      expect(result.text, 'bold');
    });

    test('with nothing selected it leaves the caret between the markers', () {
      final result = InlineFormat.toggle(
        valueOf('ab', start: 1, end: 1),
        InlineMark.italic,
      );

      expect(result.text, 'a**b');
      expect(result.selection.baseOffset, 2);
      expect(result.selection.isCollapsed, isTrue);
    });

    test('each mark uses its own markers', () {
      expect(
        InlineFormat.toggle(valueOf('x'), InlineMark.strikethrough).text,
        '~~x~~',
      );
      expect(
        InlineFormat.toggle(valueOf('x'), InlineMark.code).text,
        '`x`',
      );
    });

    test('bold and italic nest rather than fighting', () {
      final bold = InlineFormat.toggle(valueOf('x'), InlineMark.bold);
      final both = InlineFormat.toggle(bold, InlineMark.italic);

      expect(both.text, '***x***');
    });

    test('an invalid selection is left alone', () {
      const value = TextEditingValue(text: 'x');

      expect(InlineFormat.toggle(value, InlineMark.bold), value);
    });
  });

  group('clear', () {
    test('strips every mark from the selection', () {
      final result = InlineFormat.clear(
        valueOf('**bold** and *italic* and `code`'),
      );

      expect(result.text, 'bold and italic and code');
    });

    test('leaves text outside the selection untouched', () {
      final result = InlineFormat.clear(
        valueOf('**keep** **strip**', start: 9, end: 18),
      );

      expect(result.text, '**keep** strip');
    });

    test('does nothing with no selection', () {
      final value = valueOf('**bold**', start: 2, end: 2);

      expect(InlineFormat.clear(value), value);
    });
  });

  group('block type shortcuts', () {
    test('Ctrl+0 is a paragraph', () {
      expect(BlockTypes.forDigit(0), const NoteBlock.paragraph(''));
    });

    test('Ctrl+1 through Ctrl+6 are the header levels', () {
      for (var level = 1; level <= 6; level++) {
        expect(BlockTypes.forDigit(level)!.type, NoteBlockType.heading);
        expect(BlockTypes.forDigit(level)!.level, level);
      }
    });

    test('anything else is not a block kind', () {
      expect(BlockTypes.forDigit(7), isNull);
      expect(BlockTypes.forDigit(-1), isNull);
    });

    test('the menu lists what it claims in its hints', () {
      // The hint is what the block actually writes, so they must agree.
      for (final choice in [...BlockTypes.basic, ...BlockTypes.headers]) {
        if (choice.block.type == NoteBlockType.heading) {
          expect(choice.hint, '${'#' * choice.block.level} Header');
        }
      }
    });
  });

  group('horizontal rules', () {
    test('three dashes parse as a rule', () {
      expect(NoteBlocks.parse('---'), [const NoteBlock.divider()]);
      expect(NoteBlocks.parse('***'), [const NoteBlock.divider()]);
      expect(NoteBlocks.parse('___'), [const NoteBlock.divider()]);
    });

    test('a rule writes back as three dashes', () {
      expect(
        NoteBlocks.serialize(const [
          NoteBlock.paragraph('above'),
          NoteBlock.divider(),
          NoteBlock.paragraph('below'),
        ]),
        'above\n\n---\n\nbelow',
      );
    });

    test('typing three dashes converts the line', () {
      expect(
        NoteBlocks.shortcutFor(const NoteBlock.paragraph(''), '---'),
        const NoteBlock.divider(),
      );
    });

    test('a rule round-trips', () {
      const source = 'above\n\n---\n\nbelow';

      expect(NoteBlocks.serialize(NoteBlocks.parse(source)), source);
    });
  });
}
