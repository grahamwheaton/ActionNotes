import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../markdown/project_markdown.dart';
import '../models/canvas_layout.dart';
import '../models/project.dart';
import 'attachment_store.dart';

typedef ProjectCopyData = ({
  String markdown,
  String layout,
  Map<String, Uint8List> attachments,
});

/// A portable copy: one markdown project, its canvas positions and its images.
class ProjectCopy {
  ProjectCopy._();

  static Future<Uint8List> encode(Project project, CanvasLayout layout,
      Future<List<int>?> Function(String reference) imageBytes) async {
    final markdown = ProjectMarkdown.serialize(project);
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('project.md', utf8.encode(markdown)))
      ..addFile(ArchiveFile.bytes('canvas.json',
        utf8.encode(layout.toJsonString())));
    final names = RegExp(r'\.\./attachments/[^/\s)]+/([A-Za-z0-9._-]+)')
        .allMatches(markdown).map((match) => match.group(1)!).toSet();
    for (final name in names) {
      final reference = AttachmentStore.markdownPath(project.fileSlug, name);
      final bytes = await imageBytes(reference);
      if (bytes == null) throw StateError('Could not load attachment $name');
      archive.addFile(ArchiveFile.bytes('attachments/$name', bytes));
    }
    return ZipEncoder().encodeBytes(archive);
  }

  static ProjectCopyData decode(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    String? markdown;
    String? layout;
    final attachments = <String, Uint8List>{};
    for (final entry in archive) {
      if (!entry.isFile || entry.size > 32 * 1024 * 1024) continue;
      if (entry.name == 'project.md') {
        markdown = utf8.decode(entry.content);
      } else if (entry.name == 'canvas.json') {
        layout = utf8.decode(entry.content);
      } else if (RegExp(r'^attachments/[A-Za-z0-9._-]+$')
          .hasMatch(entry.name)) {
        attachments[entry.name.substring('attachments/'.length)] =
            entry.content;
      }
    }
    if (markdown == null || layout == null) {
      throw const FormatException('Not an ActionNotes project copy');
    }
    return (markdown: markdown, layout: layout, attachments: attachments);
  }
}
