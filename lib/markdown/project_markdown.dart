import '../models/checklist_item.dart';
import '../models/project.dart';

/// Reads and writes the format described in `docs/FILE_FORMAT.md`.
///
/// Reading is deliberately forgiving — a file hand-edited on GitHub, or written
/// by a model, should still open. Writing is canonical so diffs stay small.
class ProjectMarkdown {
  ProjectMarkdown._();

  /// Item notes are indented by this much beneath their item.
  static const _noteIndent = '  ';

  /// Written before the text of a starred item. Read leniently: a hollow star
  /// or a plain asterisk pair means the same thing.
  static const starMarker = '⭐';

  static final _frontMatterFence = RegExp(r'^---\s*$');
  static final _headingPattern = RegExp(r'^#\s+(.*)$');

  /// A block heading. Two or more hashes, so the project's own `# Title` is
  /// not one. Deeper headings are blocks too rather than nesting, because one
  /// level is what the app offers and a `###` typed on GitHub should still
  /// land somewhere rather than be swallowed into the block above it.
  static final _blockPattern = RegExp(r'^#{2,}\s+(.*)$');

  /// Deliberately anchored at column 0: an indented `- [ ]` belongs to the
  /// note above it, which is how a checklist inside a note stays inside it
  /// rather than being read as another item of the project.
  static final _itemPattern = RegExp(r'^[-*+]\s+\[([ xX])\]\s?(.*)$');
  static final _starPattern = RegExp(r'^(?:⭐|★|\*\*)\s*');

  static Project parse(String source, {required String slug, String? sha}) {
    final lines = source.replaceAll('\r\n', '\n').split('\n');
    var index = 0;

    final frontMatter = <String, String>{};
    if (lines.isNotEmpty && _frontMatterFence.hasMatch(lines.first)) {
      index = 1;
      while (index < lines.length &&
          !_frontMatterFence.hasMatch(lines[index])) {
        final line = lines[index];
        final colon = line.indexOf(':');
        if (colon > 0) {
          final key = line.substring(0, colon).trim();
          final value = line.substring(colon + 1).trim();
          if (key.isNotEmpty) frontMatter[key] = value;
        }
        index++;
      }
      // Step past the closing fence, if the file has one.
      if (index < lines.length) index++;
    }

    String? headingTitle;
    final items = <ChecklistItem>[];
    final projectNotes = <String>[];

    // The `##` sections, in the order they appear, and the prose under each.
    final blocks = <String>[];
    final blockBody = <String, List<String>>{};

    // Which block the lines being read belong to. Null until the first
    // heading, which is where a project written before blocks stays.
    String? currentBlock;

    // Non-null while lines could still belong to the item just read.
    List<String>? itemNotes;

    void flushItemNotes() {
      if (itemNotes == null || items.isEmpty) {
        itemNotes = null;
        return;
      }
      final notes = _trimBlankEdges(itemNotes!).join('\n');
      if (notes.isNotEmpty) {
        items[items.length - 1] = items.last.copyWith(notes: notes);
      }
      itemNotes = null;
    }

    for (; index < lines.length; index++) {
      final line = lines[index];

      // A heading only starts a block outside an item's notes: an indented
      // `## ` belongs to the note above it, the same as an indented item does.
      if (itemNotes == null || !_isIndented(line)) {
        final block = _blockPattern.firstMatch(line);
        if (block != null) {
          flushItemNotes();
          final title = block.group(1)!.trim();
          if (title.isNotEmpty) {
            // A repeated heading joins the first one rather than becoming a
            // second block of the same name, since the items name their block
            // and two of one name could not be told apart.
            if (!blocks.contains(title)) {
              blocks.add(title);
              blockBody[title] = <String>[];
            }
            currentBlock = title;
            continue;
          }
        }
      }

      // Inside a section, an indented checklist line is part of that
      // section's prose rather than another of its items — the same rule that
      // keeps a checklist inside an item's notes inside them. At column 0 it
      // is an item, so a list written under a heading on GitHub still reads
      // as one.
      final item = _isIndented(line) && currentBlock != null
          ? null
          : _itemPattern.firstMatch(line);
      if (item != null) {
        // A blank line just before the next item is a gap someone typed, not
        // the start of an empty note — whether or not the item above had
        // notes of its own. Remember it on that item so that saving the file
        // does not quietly close the gap up.
        if (itemNotes != null &&
            itemNotes!.isNotEmpty &&
            itemNotes!.last.trim().isEmpty &&
            items.isNotEmpty) {
          items[items.length - 1] = items.last.copyWith(blankAfter: true);
        }
        flushItemNotes();

        var text = item.group(2)!.trim();
        final starred = _starPattern.hasMatch(text);
        if (starred) text = text.replaceFirst(_starPattern, '').trim();

        items.add(
          ChecklistItem(
            text: text,
            done: item.group(1)!.toLowerCase() == 'x',
            starred: starred,
            block: currentBlock,
          ),
        );
        itemNotes = <String>[];
        continue;
      }

      if (itemNotes != null) {
        // A blank line may sit inside a note block, so keep it for now and let
        // the flush trim it if the block ended here.
        if (line.trim().isEmpty) {
          itemNotes!.add('');
          continue;
        }
        if (line.startsWith(' ') || line.startsWith('\t')) {
          itemNotes!.add(_dedent(line));
          continue;
        }
        // Unindented text ends the item's notes and belongs to the project.
        flushItemNotes();
      }

      if (headingTitle == null && items.isEmpty) {
        final heading = _headingPattern.firstMatch(line);
        if (heading != null) {
          headingTitle = heading.group(1)!.trim();
          continue;
        }
      }

      if (currentBlock == null) {
        projectNotes.add(line);
      } else {
        blockBody[currentBlock]!.add(_dedent(line));
      }
    }
    flushItemNotes();

    final extra = Map<String, String>.from(frontMatter)
      ..remove('title')
      ..remove('created')
      ..remove('updated')
      ..remove('mode');

    return Project(
      slug: slug,
      title: _firstNonEmpty([frontMatter['title'], headingTitle, slug])!,
      items: items,
      notes: _trimBlankEdges(projectNotes).join('\n'),
      mode: ProjectMode.parse(frontMatter['mode']),
      blocks: [
        for (final title in blocks)
          ProjectBlock(
            title: title,
            body: _trimBlankEdges(blockBody[title]!).join('\n'),
          ),
      ],
      created: _parseDate(frontMatter['created']),
      updated: _parseDate(frontMatter['updated']),
      extraFrontMatter: extra,
      sha: sha,
    );
  }

  /// One item as its markdown line, plus its indented notes — the same shape
  /// [serialize] writes, so an archived item reads exactly as it did in the
  /// list.
  static String serializeItem(ChecklistItem item) {
    final buffer = StringBuffer();
    final star = item.starred ? '$starMarker ' : '';
    buffer.writeln('- [${item.done ? 'x' : ' '}] $star${item.text}');

    if (item.hasNotes) {
      for (final line in item.notes.trim().split('\n')) {
        buffer.writeln(line.isEmpty ? '' : '  $line');
      }
    }
    return buffer.toString();
  }

  static String serialize(Project project) {
    final buffer = StringBuffer()
      ..writeln('---')
      ..writeln('title: ${project.title}');

    final created = project.created ?? DateTime.now().toUtc();
    buffer.writeln('created: ${_formatDate(created)}');
    buffer.writeln('updated: ${_formatDate(project.updated ?? created)}');

    // Only when it is not the default, so a checklist's file is unchanged by
    // this existing at all.
    if (project.mode != ProjectMode.tasks) {
      buffer.writeln('mode: ${project.mode.name}');
    }

    final extraKeys = project.extraFrontMatter.keys.toList()..sort();
    for (final key in extraKeys) {
      buffer.writeln('$key: ${project.extraFrontMatter[key]}');
    }

    buffer
      ..writeln('---')
      ..writeln()
      ..writeln('# ${project.title}')
      ..writeln();

    void writeItems(String? block) {
      final within = [
        for (final item in project.items)
          if (item.block == block) item,
      ];

      for (var i = 0; i < within.length; i++) {
        final item = within[i];
        final star = item.starred ? '$starMarker ' : '';
        buffer.writeln('- [${item.done ? 'x' : ' '}] $star${item.text}');

        if (item.hasNotes) {
          for (final line in item.notes.trim().split('\n')) {
            // Keep blank lines genuinely blank rather than indented
            // whitespace.
            buffer.writeln(line.trim().isEmpty ? '' : '$_noteIndent$line');
          }
        }

        // Only between two items: after the last one the blank line would be
        // the one that separates the list from whatever comes next, and two
        // of those read as a gap that nobody typed.
        if (item.blankAfter && i < within.length - 1) buffer.writeln();
      }
    }

    // Everything above the first heading first, exactly as a project without
    // blocks has always been written.
    writeItems(null);

    final notes = project.notes.trim();
    if (notes.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(notes);
    }

    // An item naming a block the project does not list would otherwise be
    // dropped, so the headings written are the listed ones plus any the items
    // ask for, in the order the items ask.
    final written = <String>{};
    final headings = <String>[for (final block in project.blocks) block.title];
    for (final item in project.items) {
      final block = item.block;
      if (block != null && !headings.contains(block)) headings.add(block);
    }

    for (final title in headings) {
      if (!written.add(title)) continue;
      buffer
        ..writeln()
        ..writeln('## $title')
        ..writeln();
      // The prose comes before the items, and indented, for one reason each.
      //
      // Indented, the same as an item's notes are: a `- [ ]` written inside a
      // section's prose is part of that prose, and at column 0 it would be
      // read back as another item of the section — which is exactly what went
      // wrong, a checklist typed into a section's notes turning into the
      // section's items the next time the file was opened. Reading stays
      // forgiving, so unindented prose typed on GitHub is still the body.
      //
      // Before the items, because an indented line that follows an item is
      // that item's notes, and there is no way to tell where those end and a
      // section's prose begins. Above them there is no ambiguity at all — and
      // a heading, a paragraph, then a list is the order a document is
      // written in anyway.
      final body = project.blocks
          .firstWhere(
            (block) => block.title == title,
            orElse: () => const ProjectBlock(title: '', body: ''),
          )
          .body
          .trim();
      if (body.isNotEmpty) {
        for (final line in body.split('\n')) {
          buffer.writeln(line.trim().isEmpty ? '' : '$_noteIndent$line');
        }
        if (project.items.any((item) => item.block == title)) buffer.writeln();
      }

      writeItems(title);
    }

    return buffer.toString();
  }

  static bool _isIndented(String line) =>
      line.startsWith(' ') || line.startsWith('\t');

  /// Removes one level of note indentation, tolerating tabs and deeper indents
  /// from hand-edited files.
  static String _dedent(String line) {
    if (line.startsWith(_noteIndent)) return line.substring(_noteIndent.length);
    if (line.startsWith('\t')) return line.substring(1);
    return line.trimLeft();
  }

  static String? _firstNonEmpty(List<String?> candidates) {
    for (final candidate in candidates) {
      if (candidate != null && candidate.trim().isNotEmpty) {
        return candidate.trim();
      }
    }
    return null;
  }

  static DateTime? _parseDate(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }

  static String _formatDate(DateTime date) =>
      '${date.toUtc().toIso8601String().split('.').first}Z';

  static List<String> _trimBlankEdges(List<String> lines) {
    var start = 0;
    var end = lines.length;
    while (start < end && lines[start].trim().isEmpty) {
      start++;
    }
    while (end > start && lines[end - 1].trim().isEmpty) {
      end--;
    }
    return lines.sublist(start, end);
  }
}
