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
      while (index < lines.length && !_frontMatterFence.hasMatch(lines[index])) {
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

      final item = _itemPattern.firstMatch(line);
      if (item != null) {
        flushItemNotes();

        var text = item.group(2)!.trim();
        final starred = _starPattern.hasMatch(text);
        if (starred) text = text.replaceFirst(_starPattern, '').trim();

        items.add(ChecklistItem(
          text: text,
          done: item.group(1)!.toLowerCase() == 'x',
          starred: starred,
        ));
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

      projectNotes.add(line);
    }
    flushItemNotes();

    final extra = Map<String, String>.from(frontMatter)
      ..remove('title')
      ..remove('created')
      ..remove('updated');

    return Project(
      slug: slug,
      title: _firstNonEmpty([frontMatter['title'], headingTitle, slug])!,
      items: items,
      notes: _trimBlankEdges(projectNotes).join('\n'),
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

    final extraKeys = project.extraFrontMatter.keys.toList()..sort();
    for (final key in extraKeys) {
      buffer.writeln('$key: ${project.extraFrontMatter[key]}');
    }

    buffer
      ..writeln('---')
      ..writeln()
      ..writeln('# ${project.title}')
      ..writeln();

    for (final item in project.items) {
      final star = item.starred ? '$starMarker ' : '';
      buffer.writeln('- [${item.done ? 'x' : ' '}] $star${item.text}');

      if (item.hasNotes) {
        for (final line in item.notes.trim().split('\n')) {
          // Keep blank lines genuinely blank rather than indented whitespace.
          buffer.writeln(line.trim().isEmpty ? '' : '$_noteIndent$line');
        }
      }
    }

    final notes = project.notes.trim();
    if (notes.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(notes);
    }

    return buffer.toString();
  }

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
