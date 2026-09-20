import 'dart:convert';

import '../models/notes_source.dart';
import 'share_code.dart';

/// The list of shared notebooks, kept in your own repo so that every device
/// signed in to it finds the same ones.
///
/// Without this a notebook lives only on the device the code was pasted into.
/// Share a project from your phone and your desktop simply loses it: the file
/// has left your own repo, the desktop has never heard of the notebook it went
/// to, and there is nothing on screen to explain where it went.
///
/// It holds share codes rather than anything of its own, because a share code
/// already is exactly this: everything needed to reach a notebook, in one
/// string. The code carries a token, so this is written only into a private
/// repo — see [NotebookIndex.path] and the check at the call site.
class NotebookIndex {
  const NotebookIndex(this.entries, {this.sha});

  final List<NotebookEntry> entries;

  /// The SHA it was read at, so writing it back cannot clobber a change made
  /// from another device between the two.
  final String? sha;

  /// Out of the way of `projects/`, which is the part of the repo anybody
  /// reads by hand.
  static const path = '.actionnotes/notebooks.json';

  static const empty = NotebookIndex([]);

  bool get isEmpty => entries.isEmpty;

  static NotebookIndex parse(String content, {String? sha}) {
    try {
      final decoded = jsonDecode(content);
      if (decoded is! List) return NotebookIndex(const [], sha: sha);

      return NotebookIndex([
        for (final entry in decoded.whereType<Map<String, dynamic>>())
          if (NotebookEntry.fromJson(entry) case final one?) one,
      ], sha: sha);
    } catch (_) {
      // A file somebody has edited by hand into something unreadable should
      // not stop the app starting. An empty index means "no notebooks known
      // from here", which is what it was before this file existed.
      return NotebookIndex(const [], sha: sha);
    }
  }

  String serialize() {
    const encoder = JsonEncoder.withIndent('  ');
    return '${encoder.convert([for (final entry in entries) entry.toJson()])}\n';
  }

  /// The notebooks this index describes, as the app holds them.
  List<NotesSource> get sources => [
    for (final entry in entries)
      if (ShareCode.decode(entry.code) case final config?)
        NotesSource.sharedFrom(config, label: entry.label),
  ];

  /// Builds one from the notebooks in hand.
  static NotebookIndex of(Iterable<NotesSource> sources, {String? sha}) {
    return NotebookIndex([
      for (final source in sources)
        if (!source.isMine)
          NotebookEntry(
            code: ShareCode.encode(source.config),
            label: source.label,
          ),
    ], sha: sha);
  }

  /// Whether this says something different from that, ignoring order — so the
  /// file is only rewritten when it would actually change.
  bool sameAs(NotebookIndex other) {
    final mine = entries.map((e) => '${e.code}\u0000${e.label}').toSet();
    final theirs = other.entries
        .map((e) => '${e.code}\u0000${e.label}')
        .toSet();
    return mine.length == theirs.length && mine.containsAll(theirs);
  }
}

class NotebookEntry {
  const NotebookEntry({required this.code, this.label = ''});

  /// The same string somebody would paste to join. Deliberately not the owner,
  /// repo, branch and token spelled out: one field that is already understood
  /// beats four that have to be kept in step.
  final String code;

  final String label;

  static NotebookEntry? fromJson(Map<String, dynamic> json) {
    final code = json['code'];
    if (code is! String || code.trim().isEmpty) return null;
    return NotebookEntry(
      code: code.trim(),
      label: (json['label'] as String?)?.trim() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'code': code,
    if (label.isNotEmpty) 'label': label,
  };
}
