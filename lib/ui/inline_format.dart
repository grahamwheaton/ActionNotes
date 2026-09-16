import 'package:flutter/services.dart';

/// The inline marks the formatting toolbar can apply.
enum InlineMark {
  bold('**', 'Bold'),
  italic('*', 'Italic'),
  strikethrough('~~', 'Strikethrough'),
  code('`', 'Code');

  const InlineMark(this.marker, this.label);

  final String marker;
  final String label;
}

/// Wraps and unwraps markdown marks around a selection.
///
/// Kept as pure functions over a [TextEditingValue] so the behaviour can be
/// tested without a widget, and so applying a mark is the same operation
/// whether it came from the toolbar or a keyboard shortcut.
class InlineFormat {
  InlineFormat._();

  /// Adds [mark] around the selection, or takes it away when it is already
  /// there — so the same button turns bold on and off.
  ///
  /// With nothing selected, inserts the pair and leaves the caret between
  /// them, ready to type.
  static TextEditingValue toggle(TextEditingValue value, InlineMark mark) {
    final selection = value.selection;
    if (!selection.isValid) return value;

    final marker = mark.marker;
    final text = value.text;
    final start = selection.start;
    final end = selection.end;

    // Already wrapped, either inside the selection or just outside it.
    //
    // The run lengths have to match exactly. `**` ends with `*`, so a loose
    // check would have italic strip a marker off bold text instead of nesting
    // inside it.
    final inside = text.substring(start, end);
    if (inside.length >= marker.length * 2 &&
        _runAt(inside, 0, marker) == marker.length &&
        _runBefore(inside, inside.length, marker) == marker.length) {
      final stripped = inside.substring(
        marker.length,
        inside.length - marker.length,
      );
      return TextEditingValue(
        text: text.replaceRange(start, end, stripped),
        selection: TextSelection(
          baseOffset: start,
          extentOffset: start + stripped.length,
        ),
      );
    }

    final before = text.substring(0, start);
    final after = text.substring(end);
    if (_runBefore(before, before.length, marker) == marker.length &&
        _runAt(after, 0, marker) == marker.length) {
      return TextEditingValue(
        text: before.substring(0, before.length - marker.length) +
            inside +
            after.substring(marker.length),
        selection: TextSelection(
          baseOffset: start - marker.length,
          extentOffset: start - marker.length + inside.length,
        ),
      );
    }

    final wrapped = '$marker$inside$marker';
    return TextEditingValue(
      text: text.replaceRange(start, end, wrapped),
      selection: selection.isCollapsed
          ? TextSelection.collapsed(offset: start + marker.length)
          : TextSelection(
              baseOffset: start + marker.length,
              extentOffset: start + marker.length + inside.length,
            ),
    );
  }

  /// How many of [marker]'s character run forwards from [index].
  static int _runAt(String text, int index, String marker) {
    final char = marker[0];
    var count = 0;
    while (index + count < text.length && text[index + count] == char) {
      count++;
    }
    return count;
  }

  /// How many of [marker]'s character run backwards from [index].
  static int _runBefore(String text, int index, String marker) {
    final char = marker[0];
    var count = 0;
    while (index - count - 1 >= 0 && text[index - count - 1] == char) {
      count++;
    }
    return count;
  }

  /// Strips every inline mark from the selection, which is what MarkText's
  /// eraser does.
  static TextEditingValue clear(TextEditingValue value) {
    final selection = value.selection;
    if (!selection.isValid || selection.isCollapsed) return value;

    final inside = value.text.substring(selection.start, selection.end);
    // Longest markers first, so `**` is not mistaken for two `*`.
    var stripped = inside;
    for (final marker in ['***', '**', '~~', '__', '*', '_', '`']) {
      stripped = stripped.replaceAll(marker, '');
    }

    return TextEditingValue(
      text: value.text.replaceRange(selection.start, selection.end, stripped),
      selection: TextSelection(
        baseOffset: selection.start,
        extentOffset: selection.start + stripped.length,
      ),
    );
  }
}
