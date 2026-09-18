import 'note_conversation.dart';

/// `@name` in an item or its notes: a way to ask someone — usually a model —
/// to pick something up.
///
/// The point is that it works from either side. Written in the app it is
/// plain text a model reading the repo will find; written by a model it shows
/// up in the app without anything having to be synced but the file.
class Mentions {
  Mentions._();

  /// `@name` at a word boundary. Letters, digits, dashes and dots, so
  /// `@Claude` and `@chat-gpt` both read, and an email address does not:
  /// there the `@` follows a word character.
  static final _pattern = RegExp(r'(?<![\w@./])@([A-Za-z][A-Za-z0-9.\-]{0,30})');

  /// Code spans and fenced blocks, whose contents are being talked about
  /// rather than said. Writing `@Claude` about the convention should not ask
  /// Claude for anything — which is exactly what happened the first time
  /// these notes described the feature.
  static final _code = RegExp(r'```[\s\S]*?```|`[^`\n]*`');

  /// Every name mentioned in [text], in order, each once, case as written.
  static List<String> parse(String text) {
    final found = <String, String>{};

    // Blanked rather than removed, so nothing either side of a code span can
    // be joined into a name that was never written.
    final prose = text.replaceAllMapped(
      _code,
      (match) => ' ' * match.group(0)!.length,
    );

    for (final match in _pattern.allMatches(prose)) {
      final name = match.group(1)!;
      // A trailing dot is sentence punctuation, not part of a name.
      final cleaned = name.replaceAll(RegExp(r'[.\-]+$'), '');
      if (cleaned.isEmpty) continue;
      found.putIfAbsent(cleaned.toLowerCase(), () => cleaned);
    }

    return found.values.toList();
  }

  /// Whether [text] mentions [name], however it was capitalised.
  static bool mentions(String text, String name) {
    final wanted = name.trim().toLowerCase().replaceFirst('@', '');
    return parse(text).any((found) => found.toLowerCase() == wanted);
  }

  /// The name a query is asking for — `@claude` typed into the search box —
  /// or null for an ordinary search.
  static String? queryName(String query) {
    final match = RegExp(r'^@([A-Za-z][A-Za-z0-9.\-]{0,30})$')
        .firstMatch(query.trim());
    return match?.group(1);
  }

  /// Who an item is still waiting on.
  ///
  /// A mention is answered by a reply, not by being deleted: a name is
  /// waiting only while the last message in the note is from someone else.
  /// That way a conversation can mention a model repeatedly without the item
  /// looking unanswered forever, and nothing has to be edited away to mark it
  /// done — which matters when the other party is a model that has been told
  /// not to delete anything.
  static List<String> awaiting({required String text, required String notes}) {
    final mentioned = <String, String>{};
    for (final name in [...parse(text), ...parse(notes)]) {
      mentioned.putIfAbsent(name.toLowerCase(), () => name);
    }
    if (mentioned.isEmpty) return const [];

    final messages = NoteConversation.parse(notes);
    final lastSpeaker = messages.isEmpty ? null : messages.last.speaker;
    if (lastSpeaker == null) return mentioned.values.toList();

    final answered = lastSpeaker.trim().toLowerCase();
    return [
      for (final entry in mentioned.entries)
        if (entry.key != answered) entry.value,
    ];
  }
}
