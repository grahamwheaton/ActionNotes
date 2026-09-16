import '../models/checklist_item.dart';
import '../models/project.dart';

/// How to settle a project that changed both on this device and on GitHub.
enum ConflictResolution {
  /// Overwrite GitHub with this device's copy.
  keepLocal,

  /// Discard this device's copy and take GitHub's.
  keepRemote,

  /// Combine both, keeping every item from either side.
  merge,
}

/// Combines two versions of a project without losing items.
///
/// Checklists merge more safely than prose: an item is identified by its text,
/// so the union of both sides is usually what someone means by "merge". The
/// cost is that an item deleted on one side but still present on the other
/// comes back — deletions cannot be told apart from never-having-existed
/// without a history, and resurrecting an item is easier to spot and undo than
/// silently dropping one.
class ProjectMerge {
  ProjectMerge._();

  static Project merge({required Project local, required Project remote}) {
    final remaining = <String, ChecklistItem>{};
    for (final item in remote.items) {
      remaining[_key(item.text)] = item;
    }

    final items = <ChecklistItem>[];

    // Local order leads, so the list still looks like the one in front of you.
    for (final item in local.items) {
      final counterpart = remaining.remove(_key(item.text));
      items.add(counterpart == null ? item : _combine(item, counterpart));
    }

    // Anything only on GitHub goes after, in its own order.
    for (final item in remote.items) {
      final counterpart = remaining.remove(_key(item.text));
      if (counterpart != null) items.add(counterpart);
    }

    return local.copyWith(
      // A rename on either side has to lose; the local title is the one the
      // person is looking at.
      title: local.title,
      items: items,
      notes: _mergeText(local.notes, remote.notes),
      updated: DateTime.now().toUtc(),
      // Front matter keys only GitHub knows about are worth keeping.
      extraFrontMatter: {...remote.extraFrontMatter, ...local.extraFrontMatter},
    );
  }

  /// Ticked or starred on either side wins, so a completion made on the phone
  /// is not undone by a stale desktop copy.
  static ChecklistItem _combine(ChecklistItem local, ChecklistItem remote) {
    return local.copyWith(
      done: local.done || remote.done,
      starred: local.starred || remote.starred,
      notes: _mergeText(local.notes, remote.notes),
    );
  }

  /// Keeps both sides when they differ, rather than picking one and losing the
  /// other. The marker makes it obvious something needs tidying by hand.
  static String _mergeText(String local, String remote) {
    final mine = local.trim();
    final theirs = remote.trim();
    if (mine == theirs) return mine;
    if (mine.isEmpty) return theirs;
    if (theirs.isEmpty) return mine;
    return '$mine\n\n<!-- from GitHub -->\n$theirs';
  }

  /// Items match on their text, ignoring case and surrounding space.
  static String _key(String text) => text.trim().toLowerCase();
}
