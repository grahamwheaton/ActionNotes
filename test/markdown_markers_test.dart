import 'package:actionnotes/ui/markdown_text_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds the spans the field would paint, so the test sees exactly what a
/// reader would.
Future<List<InlineSpan>> spansFor(
  WidgetTester tester,
  MarkdownTextController controller,
) async {
  late TextSpan span;

  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          span = controller.buildTextSpan(
            context: context,
            style: const TextStyle(fontSize: 14, color: Color(0xFF000000)),
            withComposing: false,
          );
          return const SizedBox();
        },
      ),
    ),
  );

  return span.children ?? const [];
}

/// A marker that is out of the way is laid out at no width, not merely
/// greyed, so it takes up no room on the line.
bool isHidden(InlineSpan span) => (span.style?.fontSize ?? 14) < 1;

String textOf(InlineSpan span) => (span as TextSpan).text ?? '';

void main() {
  testWidgets('markers are out of the way when the caret is elsewhere',
      (tester) async {
    final controller = MarkdownTextController(text: 'a **bold** word')
      ..selection = const TextSelection.collapsed(offset: 0);

    final spans = await spansFor(tester, controller);
    final markers = spans.where((s) => textOf(s) == '**');

    expect(markers, hasLength(2));
    expect(markers.every(isHidden), isTrue);
  });

  testWidgets('the word itself is still bold with the markers hidden',
      (tester) async {
    final controller = MarkdownTextController(text: 'a **bold** word')
      ..selection = const TextSelection.collapsed(offset: 0);

    final spans = await spansFor(tester, controller);
    final word = spans.firstWhere((s) => textOf(s) == 'bold');

    expect(word.style?.fontWeight, FontWeight.w700);
    expect(isHidden(word), isFalse);
  });

  testWidgets('markers come back when the caret enters the span',
      (tester) async {
    final controller = MarkdownTextController(text: 'a **bold** word')
      // Inside the word, between the markers.
      ..selection = const TextSelection.collapsed(offset: 6);

    final spans = await spansFor(tester, controller);
    final markers = spans.where((s) => textOf(s) == '**');

    expect(markers, hasLength(2));
    expect(markers.any(isHidden), isFalse);
  });

  testWidgets('a caret resting just after a span still shows its markers',
      (tester) async {
    final controller = MarkdownTextController(text: 'a **bold** word')
      // Immediately after the closing `**`, which is still editing it.
      ..selection = const TextSelection.collapsed(offset: 10);

    final spans = await spansFor(tester, controller);

    expect(spans.where((s) => textOf(s) == '**').any(isHidden), isFalse);
  });

  testWidgets('a link shows its label and hides its target', (tester) async {
    final controller = MarkdownTextController(text: 'see [Docs](docs.md) here')
      ..selection = const TextSelection.collapsed(offset: 0);

    final spans = await spansFor(tester, controller);

    expect(spans.firstWhere((s) => textOf(s) == '['), predicate(isHidden));
    expect(spans.firstWhere((s) => textOf(s) == '](docs.md)'), predicate(isHidden));

    final label = spans.firstWhere((s) => textOf(s) == 'Docs');
    expect(isHidden(label), isFalse);
    expect(label.style?.decoration, TextDecoration.underline);
  });

  testWidgets('plain text is left exactly as it is', (tester) async {
    final controller = MarkdownTextController(text: 'nothing to mark up here')
      ..selection = const TextSelection.collapsed(offset: 0);

    final spans = await spansFor(tester, controller);

    expect(spans.map(textOf).join(), 'nothing to mark up here');
    expect(spans.any(isHidden), isFalse);
  });

  testWidgets('code and italic markers hide the same way', (tester) async {
    final controller = MarkdownTextController(text: 'an *italic* and `code`')
      ..selection = const TextSelection.collapsed(offset: 0);

    final spans = await spansFor(tester, controller);

    expect(spans.firstWhere((s) => textOf(s) == '*'), predicate(isHidden));
    expect(spans.firstWhere((s) => textOf(s) == '`'), predicate(isHidden));
    expect(
      spans.firstWhere((s) => textOf(s) == 'italic').style?.fontStyle,
      FontStyle.italic,
    );
  });

  testWidgets('with no selection at all nothing is revealed', (tester) async {
    // A field that has never been focused has an invalid selection, and that
    // should read as "not editing" rather than showing every marker at once.
    final controller = MarkdownTextController(text: 'a **bold** word');

    final spans = await spansFor(tester, controller);

    expect(spans.where((s) => textOf(s) == '**').every(isHidden), isTrue);
  });
}
