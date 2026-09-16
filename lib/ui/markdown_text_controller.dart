import 'package:flutter/material.dart';

/// A controller that draws inline markdown as it is typed: `**bold**` appears
/// bold, `*italic*` italic, `` `code` `` monospaced, and a link shows its
/// label rather than its target.
///
/// The markers are collapsed to nothing until the caret enters the span they
/// belong to, then shown dimmed so they can be edited. This keeps a note
/// looking like the document it is, without the older problem of hiding a
/// marker the caret still has to travel through: the text painter lays out
/// the very spans built here, so a collapsed marker and the caret agree about
/// where everything sits. The one cost is that arrowing across a hidden
/// marker takes a keypress that moves nothing visible.
class MarkdownTextController extends TextEditingController {
  MarkdownTextController({super.text});

  static final _inline = RegExp(
    // Bold, then italic, then code, then a link. Bold first so `**` is not
    // read as two italics.
    r'(\*\*|__)(.+?)\1'
    r'|(?<!\*)(\*|_)(?!\s)(.+?)(?<!\s)\3(?!\*)'
    r'|`([^`]+)`'
    r'|\[([^\]]*)\]\(([^)\s]*)\)',
  );

  /// True when the selection touches [start]..[end], so the markers there
  /// should be visible to be edited.
  ///
  /// The bounds are inclusive: a caret resting just after a closing `**` is
  /// still editing that span, and having the markers blink away underneath it
  /// would be worse than leaving them.
  bool _isEditing(int start, int end) {
    final selection = this.selection;
    if (!selection.isValid) return false;
    return selection.start <= end && selection.end >= start;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    final dim = base.color?.withValues(alpha: 0.35) ??
        Theme.of(context).colorScheme.outline;
    final shown = base.copyWith(color: dim);

    // A marker that is not being edited is laid out at no width at all rather
    // than merely made transparent, so it takes up no room on the line.
    final hidden = base.copyWith(
      color: const Color(0x00000000),
      fontSize: 0.01,
      letterSpacing: 0,
    );

    final spans = <InlineSpan>[];
    var cursor = 0;

    for (final match in _inline.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start), style: base));
      }

      final marker = _isEditing(match.start, match.end) ? shown : hidden;

      if (match.group(2) != null) {
        final fence = match.group(1)!;
        spans
          ..add(TextSpan(text: fence, style: marker))
          ..add(TextSpan(
            text: match.group(2),
            style: base.copyWith(fontWeight: FontWeight.w700),
          ))
          ..add(TextSpan(text: fence, style: marker));
      } else if (match.group(4) != null) {
        final fence = match.group(3)!;
        spans
          ..add(TextSpan(text: fence, style: marker))
          ..add(TextSpan(
            text: match.group(4),
            style: base.copyWith(fontStyle: FontStyle.italic),
          ))
          ..add(TextSpan(text: fence, style: marker));
      } else if (match.group(5) != null) {
        spans
          ..add(TextSpan(text: '`', style: marker))
          ..add(TextSpan(
            text: match.group(5),
            style: base.copyWith(
              fontFamily: 'monospace',
              backgroundColor: dim.withValues(alpha: 0.12),
            ),
          ))
          ..add(TextSpan(text: '`', style: marker));
      } else {
        // A link: show the label as a link and keep the target out of the way
        // until somebody goes to edit it.
        spans
          ..add(TextSpan(text: '[', style: marker))
          ..add(TextSpan(
            text: match.group(6),
            style: base.copyWith(
              decoration: TextDecoration.underline,
              color: Theme.of(context).colorScheme.primary,
            ),
          ))
          ..add(TextSpan(text: '](${match.group(7)})', style: marker));
      }

      cursor = match.end;
    }

    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor), style: base));
    }

    return TextSpan(style: base, children: spans);
  }
}
