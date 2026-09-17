/// Tags written inline in an item's text, as `[tag]`.
///
/// The markdown stays the source of truth: `- [ ] Fix the sync [bug] [app]`
/// carries its own tags, readable by anything that opens the file, with no
/// index or front matter to keep in step. The app shows the same line as
/// "Fix the sync" with two pills after it.
///
/// `[tag]` is a fragment of link syntax, so what is deliberately not a tag:
/// a link's label (`[text](url)`, including an image's) and a wikilink
/// (`[[Note]]`), which the note editor already gives a meaning to.
class ItemTags {
  ItemTags._();

  /// Bracketed text that is not a link label and not a wikilink. Newlines are
  /// excluded so a tag cannot span lines, and brackets so `[a [b] c]` yields
  /// the inner one rather than something surprising.
  static final _pattern = RegExp(r'(?<!\[)\[([^\[\]\n]+)\](?![\]\(])');

  /// The tags in [text], in the order they appear, each one once.
  ///
  /// Case is kept as written but not for telling tags apart: `[Bug]` and
  /// `[bug]` are the same tag, and the first spelling wins.
  static List<String> parse(String text) {
    final found = <String, String>{};

    for (final match in _pattern.allMatches(text)) {
      final tag = match.group(1)!.trim();
      if (tag.isEmpty) continue;
      found.putIfAbsent(tag.toLowerCase(), () => tag);
    }

    return found.values.toList();
  }

  /// [text] without its tag markers, for showing beside the pills.
  ///
  /// Tidies the gaps the markers leave behind, so `Fix [bug] the sync` reads
  /// as `Fix the sync` rather than keeping a double space.
  static String strip(String text) {
    final stripped = text.replaceAll(_pattern, ' ');
    return stripped.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim();
  }

  /// Whether [text] carries [tag], ignoring case.
  static bool has(String text, String tag) {
    final wanted = tag.trim().toLowerCase();
    if (wanted.isEmpty) return false;
    return parse(text).any((found) => found.toLowerCase() == wanted);
  }

  /// The tag a query names, for `[bug]` typed into the search box, or null if
  /// the query is ordinary text.
  static String? queryTag(String query) {
    final match = RegExp(r'^\[([^\[\]\n]+)\]$').firstMatch(query.trim());
    final tag = match?.group(1)?.trim();
    return (tag == null || tag.isEmpty) ? null : tag;
  }

  /// How a tag is written, both in the markdown and in a search box.
  static String marker(String tag) => '[${tag.trim()}]';
}
