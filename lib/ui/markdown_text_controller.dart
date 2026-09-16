import 'package:flutter/material.dart';

/// A controller that draws inline markdown as it is typed: `**bold**` appears
/// bold, `*italic*` italic, `` `code` `` monospaced, and a link's label
/// underlined.
///
/// The markers stay in the text rather than being hidden. Hiding them would
/// make the caret and selection offsets disagree with the string, which breaks
/// editing in ways that are much worse than a visible asterisk — so they are
/// dimmed instead, which keeps them quiet without lying about the content.
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

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    final dim = base.color?.withValues(alpha: 0.35) ??
        Theme.of(context).colorScheme.outline;
    final marker = base.copyWith(color: dim);

    final spans = <InlineSpan>[];
    var cursor = 0;

    for (final match in _inline.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start), style: base));
      }

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
        // A link: show the label as a link and keep the target quiet.
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
