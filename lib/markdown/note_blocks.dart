/// The kinds of line the note editor understands as a block.
enum NoteBlockType { paragraph, heading, bullet, task, image, divider, table }

/// One line-level piece of a note.
///
/// Notes are edited as a stack of these rather than as raw text, so a heading
/// can be drawn at heading size and an image can be drawn as the picture while
/// it is being edited. Anything the editor does not model stays a paragraph and
/// round-trips as written, so no note is ever damaged by being opened.
class NoteBlock {
  const NoteBlock({
    required this.type,
    this.text = '',
    this.level = 1,
    this.indent = 0,
    this.done = false,
    this.imagePath = '',
    this.imageAlt = '',
  });

  const NoteBlock.paragraph(String text)
      : this(type: NoteBlockType.paragraph, text: text);

  const NoteBlock.heading(String text, {int level = 1})
      : this(type: NoteBlockType.heading, text: text, level: level);

  const NoteBlock.bullet(String text, {int indent = 0})
      : this(type: NoteBlockType.bullet, text: text, indent: indent);

  const NoteBlock.task(String text, {bool done = false, int indent = 0})
      : this(
          type: NoteBlockType.task,
          text: text,
          done: done,
          indent: indent,
        );

  const NoteBlock.image({required String path, String alt = ''})
      : this(type: NoteBlockType.image, imagePath: path, imageAlt: alt);

  const NoteBlock.divider() : this(type: NoteBlockType.divider);

  const NoteBlock.table([String text = '| Column 1 | Column 2 |\n| --- | --- |\n|  |  |'])
      : this(type: NoteBlockType.table, text: text);

  final NoteBlockType type;

  /// The block's text, without its markdown marker — a heading's `##` and a
  /// bullet's `-` live in [type] and [level] instead, which is what lets the
  /// editor hide them.
  final String text;

  /// Heading depth, 1 to 6. Meaningless for other types.
  final int level;

  /// Nesting depth for bullets and tasks, so a list can sit inside a list.
  /// Written as two spaces per level.
  final int indent;

  /// Whether a task is ticked. Meaningless for other types.
  final bool done;

  final String imagePath;
  final String imageAlt;

  /// Whether the block is edited as text. Images and rules are not.
  bool get isText =>
      type != NoteBlockType.image && type != NoteBlockType.divider &&
      type != NoteBlockType.table;

  /// Whether the block is a list row, and so can be nested.
  bool get isListRow =>
      type == NoteBlockType.bullet || type == NoteBlockType.task;

  NoteBlock copyWith({
    NoteBlockType? type,
    String? text,
    int? level,
    int? indent,
    bool? done,
    String? imagePath,
    String? imageAlt,
  }) {
    return NoteBlock(
      type: type ?? this.type,
      text: text ?? this.text,
      level: level ?? this.level,
      indent: indent ?? this.indent,
      done: done ?? this.done,
      imagePath: imagePath ?? this.imagePath,
      imageAlt: imageAlt ?? this.imageAlt,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NoteBlock &&
      other.type == type &&
      other.text == text &&
      other.level == level &&
      other.indent == indent &&
      other.done == done &&
      other.imagePath == imagePath &&
      other.imageAlt == imageAlt;

  @override
  int get hashCode =>
      Object.hash(type, text, level, indent, done, imagePath, imageAlt);

  @override
  String toString() => switch (type) {
        NoteBlockType.heading => 'H$level($text)',
        NoteBlockType.bullet => 'Bullet@$indent($text)',
        NoteBlockType.task => 'Task@$indent(${done ? 'x' : ' '} $text)',
        NoteBlockType.image => 'Image($imagePath)',
        NoteBlockType.divider => 'Divider()',
        NoteBlockType.table => 'Table($text)',
        NoteBlockType.paragraph => 'P($text)',
      };
}

/// Converts between a note's markdown and the blocks the editor edits.
class NoteBlocks {
  NoteBlocks._();

  static final _heading = RegExp(r'^(#{1,6})\s+(.*)$');
  static final _task = RegExp(r'^(\s*)[-*+]\s+\[([ xX])\]\s?(.*)$');
  static final _bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$');

  /// Two spaces per nesting level, which is what the serializer writes and
  /// what every markdown renderer reads back.
  static const _indentWidth = 2;
  static const _maxIndent = 5;

  /// An image alone on its line. Anything else containing an image stays a
  /// paragraph, so mixed content is never rearranged.
  static final _image = RegExp(r'^!\[([^\]]*)\]\(([^)\s]+)\)$');

  /// A thematic break, in any of the three forms markdown allows.
  static final _divider = RegExp(r'^(?:-{3,}|\*{3,}|_{3,})$');

  /// Leading whitespace to a nesting level, rounding a hand-written odd
  /// indent down rather than refusing it.
  static int _indentOf(String whitespace) {
    final spaces = whitespace.replaceAll('\t', '  ').length;
    return (spaces ~/ _indentWidth).clamp(0, _maxIndent);
  }

  static List<NoteBlock> parse(String markdown) {
    final blocks = <NoteBlock>[];

    final rawLines = markdown.replaceAll('\r\n', '\n').split('\n');
    for (var index = 0; index < rawLines.length; index++) {
      final raw = rawLines[index];
      final line = raw.trimRight();
      if (line.trim().isEmpty) continue;

      if (index + 1 < rawLines.length &&
          line.trim().startsWith('|') &&
          RegExp(r'^\|[\s:|\-]+\|$').hasMatch(rawLines[index + 1].trim()) &&
          rawLines[index + 1].contains('-')) {
        final rows = <String>[line];
        while (index + 1 < rawLines.length &&
            rawLines[index + 1].trim().startsWith('|')) {
          rows.add(rawLines[++index].trimRight());
        }
        blocks.add(NoteBlock.table(rows.join('\n')));
        continue;
      }

      if (_divider.hasMatch(line.trim())) {
        blocks.add(const NoteBlock.divider());
        continue;
      }

      final image = _image.firstMatch(line.trim());
      if (image != null) {
        blocks.add(NoteBlock.image(
          path: image.group(2)!,
          alt: image.group(1)!,
        ));
        continue;
      }

      final heading = _heading.firstMatch(line);
      if (heading != null) {
        blocks.add(NoteBlock.heading(
          heading.group(2)!.trim(),
          level: heading.group(1)!.length,
        ));
        continue;
      }

      // Tasks before bullets: `- [ ] x` is both, and the checkbox wins.
      final task = _task.firstMatch(line);
      if (task != null) {
        blocks.add(NoteBlock.task(
          task.group(3)!.trim(),
          done: task.group(2)!.toLowerCase() == 'x',
          indent: _indentOf(task.group(1)!),
        ));
        continue;
      }

      final bullet = _bullet.firstMatch(line);
      if (bullet != null) {
        blocks.add(NoteBlock.bullet(
          bullet.group(2)!.trim(),
          indent: _indentOf(bullet.group(1)!),
        ));
        continue;
      }

      blocks.add(NoteBlock.paragraph(line.trim()));
    }

    return blocks;
  }

  /// Writes blocks back to markdown.
  ///
  /// Consecutive bullets stay together as one list; everything else is
  /// separated by a blank line, which is what the renderers expect and what
  /// keeps the file readable.
  static String serialize(List<NoteBlock> blocks) {
    final lines = <String>[];
    NoteBlockType? previous;

    for (final block in blocks) {
      if (block.type == NoteBlockType.image && block.imagePath.isEmpty) {
        continue;
      }
      if (block.isText && block.text.trim().isEmpty) continue;

      const listRows = {NoteBlockType.bullet, NoteBlockType.task};
      final bothList =
          listRows.contains(previous) && listRows.contains(block.type);
      if (previous != null && !bothList) lines.add('');

      final pad = ' ' * (block.indent.clamp(0, _maxIndent) * _indentWidth);

      lines.add(switch (block.type) {
        NoteBlockType.heading =>
          '${'#' * block.level.clamp(1, 6)} ${block.text.trim()}',
        NoteBlockType.bullet => '$pad- ${block.text.trim()}',
        NoteBlockType.task =>
          '$pad- [${block.done ? 'x' : ' '}] ${block.text.trim()}',
        NoteBlockType.image => '![${block.imageAlt}](${block.imagePath})',
        NoteBlockType.divider => '---',
        NoteBlockType.table => block.text.trim(),
        NoteBlockType.paragraph => block.text.trim(),
      });

      previous = block.type;
    }

    return lines.join('\n');
  }

  /// Reads a markdown marker typed at the start of a block and returns the
  /// block it should become, or null if the text is not a marker.
  ///
  /// This is what makes typing `## ` turn a line into a heading and take the
  /// hashes away, rather than leaving them sitting in the text.
  static NoteBlock? shortcutFor(NoteBlock block, String text) {
    if (!block.isText) return null;

    final heading = RegExp(r'^(#{1,6})\s(.*)$').firstMatch(text);
    if (heading != null) {
      return block.copyWith(
        type: NoteBlockType.heading,
        level: heading.group(1)!.length,
        text: heading.group(2)!,
      );
    }

    // `- [ ] ` and `[] ` both start a checkbox.
    final task = RegExp(r'^(?:[-*+]\s)?\[([ xX]?)\]\s(.*)$').firstMatch(text);
    if (task != null && block.type != NoteBlockType.task) {
      return block.copyWith(
        type: NoteBlockType.task,
        done: task.group(1)!.toLowerCase() == 'x',
        text: task.group(2)!,
      );
    }

    final bullet = RegExp(r'^[-*+]\s(.*)$').firstMatch(text);
    if (bullet != null && block.type != NoteBlockType.bullet) {
      return block.copyWith(
        type: NoteBlockType.bullet,
        text: bullet.group(1)!,
      );
    }

    // Three dashes on their own become a rule, as they do in any markdown
    // editor — the block replaces the line rather than keeping the dashes.
    if (RegExp(r'^(?:-{3,}|\*{3,}|_{3,})$').hasMatch(text.trim())) {
      return const NoteBlock.divider();
    }

    return null;
  }
}
