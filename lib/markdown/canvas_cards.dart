/// One thing on a canvas: a picture or a piece of text.
///
/// A card is a bullet in the section's prose, which is why a canvas needs no
/// syntax of its own and degrades to an ordinary list when nothing understands
/// it. What makes a card a picture is that its markdown is one image and
/// nothing else.
class CanvasCard {
  const CanvasCard({required this.markdown, required this.imagePath});

  /// The card's markdown, exactly as the file holds it.
  final String markdown;

  /// The image this card is, or null when it is text.
  final String? imagePath;

  bool get isImage => imagePath != null;

  /// What the layout matches this card by when the indices have moved.
  ///
  /// An image's path is already unique within a project, since attachments are
  /// given unique names. Text falls back to its own opening, which is enough
  /// to recognise a card that has shifted along without being so exact that
  /// typing in it loses its place — the position is found by index first and
  /// only checked against this.
  String get ref {
    if (imagePath != null) return imagePath!;
    final text = markdown.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length <= 40 ? text : text.substring(0, 40);
  }

  @override
  bool operator ==(Object other) =>
      other is CanvasCard &&
      other.markdown == markdown &&
      other.imagePath == imagePath;

  @override
  int get hashCode => Object.hash(markdown, imagePath);

  @override
  String toString() => 'CanvasCard(${isImage ? imagePath : ref})';
}

/// Reads and writes a canvas section's body as a list of cards.
///
/// The body is an ordinary markdown bullet list, one bullet per card, so a
/// canvas read by anything else — GitHub, a model, this app with the layout
/// file missing — is a list of pictures and notes rather than nothing.
class CanvasCards {
  CanvasCards._();

  /// `- ` at the start of a line, which is how a card begins. Written with a
  /// dash; read leniently, since a hand-edited file may use any bullet.
  static final _bullet = RegExp(r'^\s*[-*+]\s+');

  /// A card that is one image and nothing else. Leading and trailing space is
  /// allowed so that a hand-written line still counts.
  static final _loneImage = RegExp(r'^!\[([^\]]*)\]\(([^)\s]+)\)$');

  static List<CanvasCard> parse(String body) {
    final cards = <CanvasCard>[];
    var current = <String>[];

    void flush() {
      final markdown = current.join('\n').trim();
      current = <String>[];
      if (markdown.isEmpty) return;
      final image = _loneImage.firstMatch(markdown);
      cards.add(
        CanvasCard(markdown: markdown, imagePath: image?.group(2)),
      );
    }

    for (final line in body.split('\n')) {
      if (_bullet.hasMatch(line)) {
        flush();
        current.add(line.replaceFirst(_bullet, ''));
        continue;
      }
      // A line under a bullet, indented to continue it, is part of that card.
      if (current.isNotEmpty) {
        current.add(line.trimLeft());
        continue;
      }
      // Anything before the first bullet is not a card. A canvas made from a
      // note that was already written keeps that note as its first card.
      current.add(line);
    }
    flush();
    return cards;
  }

  static String serialize(List<CanvasCard> cards) {
    final buffer = StringBuffer();
    for (final card in cards) {
      final lines = card.markdown.trim().split('\n');
      buffer.writeln('- ${lines.first}');
      for (final line in lines.skip(1)) {
        // Indented under its bullet, so a card that runs to several lines
        // stays one card when it is read back.
        buffer.writeln(line.trim().isEmpty ? '' : '  $line');
      }
    }
    return buffer.toString().trimRight();
  }

  /// The markdown for a picture card.
  static CanvasCard image(String path, {String alt = ''}) =>
      CanvasCard(markdown: '![$alt]($path)', imagePath: path);

  /// The markdown for a text card.
  static CanvasCard text(String value) =>
      CanvasCard(markdown: value.trim(), imagePath: null);
}
