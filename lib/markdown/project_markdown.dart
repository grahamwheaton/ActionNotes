import '../models/checklist_item.dart';
import '../models/project.dart';

/// Reads and writes the format described in `docs/FILE_FORMAT.md`.
///
/// Reading is deliberately forgiving — a file hand-edited on GitHub, or written
/// by a model, should still open. Writing is canonical so diffs stay small.
class ProjectMarkdown {
  ProjectMarkdown._();

  static final _frontMatterFence = RegExp(r'^---\s*$');
  static final _headingPattern = RegExp(r'^#\s+(.*)$');
  static final _itemPattern = RegExp(r'^\s*[-*+]\s+\[([ xX])\]\s?(.*)$');

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
    final noteLines = <String>[];

    for (; index < lines.length; index++) {
      final line = lines[index];

      final item = _itemPattern.firstMatch(line);
      if (item != null) {
        items.add(ChecklistItem(
          text: item.group(2)!.trim(),
          done: item.group(1)!.toLowerCase() == 'x',
        ));
        continue;
      }

      if (headingTitle == null && items.isEmpty) {
        final heading = _headingPattern.firstMatch(line);
        if (heading != null) {
          headingTitle = heading.group(1)!.trim();
          continue;
        }
      }

      noteLines.add(line);
    }

    final extra = Map<String, String>.from(frontMatter)
      ..remove('title')
      ..remove('created')
      ..remove('updated');

    return Project(
      slug: slug,
      title: _firstNonEmpty([frontMatter['title'], headingTitle, slug])!,
      items: items,
      notes: _trimBlankEdges(noteLines).join('\n'),
      created: _parseDate(frontMatter['created']),
      updated: _parseDate(frontMatter['updated']),
      extraFrontMatter: extra,
      sha: sha,
    );
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
      buffer.writeln('- [${item.done ? 'x' : ' '}] ${item.text}');
    }

    final notes = project.notes.trim();
    if (notes.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(notes);
    }

    return buffer.toString();
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
