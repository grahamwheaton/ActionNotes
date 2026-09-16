import 'package:actionnotes/ui/note_history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('starts with nothing to undo', () {
    final history = NoteHistory('one');

    expect(history.canUndo, isFalse);
    expect(history.canRedo, isFalse);
    expect(history.current, 'one');
  });

  test('steps back and forward through states', () {
    final history = NoteHistory('one')
      ..record('two')
      ..record('three');

    expect(history.undo(), 'two');
    expect(history.undo(), 'one');
    expect(history.canUndo, isFalse);

    expect(history.redo(), 'two');
    expect(history.redo(), 'three');
    expect(history.canRedo, isFalse);
  });

  test('returns null rather than throwing at either end', () {
    final history = NoteHistory('one');

    expect(history.undo(), isNull);
    expect(history.redo(), isNull);
  });

  test('ignores a state identical to the current one', () {
    final history = NoteHistory('one')
      ..record('one')
      ..record('one');

    expect(history.canUndo, isFalse);
  });

  test('a fresh edit after undoing discards the redo trail', () {
    final history = NoteHistory('one')
      ..record('two')
      ..record('three');

    history.undo();
    expect(history.canRedo, isTrue);

    history.record('different');
    expect(history.canRedo, isFalse);
    expect(history.undo(), 'two');
  });

  test('drops the oldest states rather than growing without bound', () {
    final history = NoteHistory('0');
    for (var i = 1; i <= NoteHistory.maxEntries + 20; i++) {
      history.record('$i');
    }

    var steps = 0;
    while (history.canUndo) {
      history.undo();
      steps++;
    }

    expect(steps, NoteHistory.maxEntries - 1);
    // The very first state has been dropped, which is the trade for a bound.
    expect(history.current, isNot('0'));
  });
}
