import '../markdown/item_tags.dart';

/// A single `- [ ]` line in a project file, plus anything indented under it.
class ChecklistItem {
  const ChecklistItem({
    required this.text,
    this.done = false,
    this.starred = false,
    this.notes = '',
  });

  final String text;
  final bool done;

  /// The "important" flag, written as a ⭐ before the item text.
  final bool starred;

  /// Markdown indented beneath the item. May reference images in the repo's
  /// attachments directory.
  final String notes;

  bool get hasNotes => notes.trim().isNotEmpty;

  /// The tags written inline in [text] as `[tag]`.
  List<String> get tags => ItemTags.parse(text);

  /// [text] without its tag markers — what the row shows beside the pills.
  /// The markers stay in [text], which is what the file holds and what an
  /// edit works on, so a tag is removed by deleting it from the line.
  String get title => ItemTags.strip(text);

  ChecklistItem copyWith({
    String? text,
    bool? done,
    bool? starred,
    String? notes,
  }) {
    return ChecklistItem(
      text: text ?? this.text,
      done: done ?? this.done,
      starred: starred ?? this.starred,
      notes: notes ?? this.notes,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ChecklistItem &&
      other.text == text &&
      other.done == done &&
      other.starred == starred &&
      other.notes == notes;

  @override
  int get hashCode => Object.hash(text, done, starred, notes);

  @override
  String toString() =>
      'ChecklistItem(${done ? 'x' : ' '}${starred ? '*' : ''} $text)';
}
