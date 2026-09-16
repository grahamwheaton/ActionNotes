/// Undo and redo for the note editor.
///
/// The editor edits a stack of blocks, so per-field undo inside a text box
/// cannot reach the edits that matter — splitting a block, merging two with
/// backspace, changing a row's kind, removing an image. History is kept over
/// the note's markdown instead, which is the one representation every edit
/// passes through, so a single stack covers all of them.
class NoteHistory {
  NoteHistory(String initial) : _entries = [initial];

  /// Beyond this, the oldest states are dropped: a note is small, but not so
  /// small that an unbounded stack is free.
  static const maxEntries = 100;

  final List<String> _entries;
  int _cursor = 0;

  String get current => _entries[_cursor];
  bool get canUndo => _cursor > 0;
  bool get canRedo => _cursor < _entries.length - 1;

  /// Records a new state. Repeats and no-ops are ignored, so holding a key
  /// does not bury the previous state under identical entries.
  void record(String markdown) {
    if (markdown == current) return;

    // A new edit after undoing discards what was undone, as usual.
    if (canRedo) _entries.removeRange(_cursor + 1, _entries.length);

    _entries.add(markdown);
    if (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
    _cursor = _entries.length - 1;
  }

  /// Steps back and returns the state to restore, or null at the beginning.
  String? undo() {
    if (!canUndo) return null;
    _cursor--;
    return current;
  }

  /// Steps forward and returns the state to restore, or null at the end.
  String? redo() {
    if (!canRedo) return null;
    _cursor++;
    return current;
  }
}
