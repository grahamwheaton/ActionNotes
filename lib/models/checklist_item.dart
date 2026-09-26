import '../markdown/item_tags.dart';
import '../markdown/mentions.dart';

/// A single `- [ ]` line in a project file, plus anything indented under it.
class ChecklistItem {
  const ChecklistItem({
    required this.text,
    this.done = false,
    this.starred = false,
    this.notes = '',
    this.block,
    this.blankAfter = false,
    this.createdAt,
    this.updatedAt,
  });

  final String text;
  final bool done;

  /// The "important" flag, written as a ⭐ before the item text.
  final bool starred;

  /// Markdown indented beneath the item. May reference images in the repo's
  /// attachments directory.
  final String notes;

  /// The `##` heading this item sits under, or null for the items above the
  /// first heading.
  ///
  /// The item keeps the label rather than the block keeping a list of items,
  /// so the project's items stay one flat list addressed by one index. Every
  /// index there is — search, reveal, move, reorder, the merge — goes on
  /// meaning what it meant before blocks existed.
  final String? block;

  /// Whether a blank line sat between this item and the next one in the file.
  ///
  /// Kept because the app should not tidy a file it was not asked to tidy: a
  /// gap someone typed to group a long list is theirs, and it also means
  /// something to markdown itself, where a blank line between list items makes
  /// a loose list that renders with more air.
  final bool blankAfter;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get hasNotes => notes.trim().isNotEmpty;

  /// The tags on this item, written as `[tag]` either on its own line or
  /// anywhere in its notes.
  ///
  /// Computed rather than stored, because the item is immutable and the text
  /// it is read from is the only copy there should be.
  List<String> get tags => ItemTags.parseAll(text: text, notes: notes);

  /// Names mentioned as `@name`, in the item or its notes.
  List<String> get mentions =>
      [...Mentions.parse(text), ...Mentions.parse(notes)];

  /// Who this item is still waiting on: a mention that has had no reply.
  List<String> get awaiting => Mentions.awaiting(text: text, notes: notes);

  /// The tags written on the item's own line, which are the ones [title]
  /// takes out. A tag from the notes is shown but not removed from anything.
  List<String> get ownTags => ItemTags.parse(text);

  /// [text] without its tag markers — what the row shows beside the pills.
  /// The markers stay in [text], which is what the file holds and what an
  /// edit works on, so a tag is removed by deleting it from the line.
  String get title => ItemTags.strip(text);

  ChecklistItem copyWith({
    String? text,
    bool? done,
    bool? starred,
    String? notes,
    String? block,
    bool clearBlock = false,
    bool? blankAfter,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return ChecklistItem(
      text: text ?? this.text,
      done: done ?? this.done,
      starred: starred ?? this.starred,
      notes: notes ?? this.notes,
      block: clearBlock ? null : (block ?? this.block),
      blankAfter: blankAfter ?? this.blankAfter,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ChecklistItem &&
      other.text == text &&
      other.done == done &&
      other.starred == starred &&
      other.notes == notes &&
      other.block == block &&
      other.blankAfter == blankAfter &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode =>
      Object.hash(text, done, starred, notes, block, blankAfter, createdAt, updatedAt);

  @override
  String toString() =>
      'ChecklistItem(${done ? 'x' : ' '}${starred ? '*' : ''} $text)';
}
