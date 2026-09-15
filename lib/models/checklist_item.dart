/// A single `- [ ] text` line in a project file.
class ChecklistItem {
  ChecklistItem({required this.text, this.done = false});

  final String text;
  final bool done;

  ChecklistItem copyWith({String? text, bool? done}) =>
      ChecklistItem(text: text ?? this.text, done: done ?? this.done);

  @override
  bool operator ==(Object other) =>
      other is ChecklistItem && other.text == text && other.done == done;

  @override
  int get hashCode => Object.hash(text, done);
}
