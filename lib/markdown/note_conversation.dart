/// A note read as a conversation.
///
/// The convention is a signed paragraph: a line holding nothing but a bold
/// name, optionally followed by `·` and when it was said, starts a message,
/// and everything until the next such line is what was said.
///
/// ```markdown
///   **Claude** · 2026-09-18T09:12Z
///   Fixed the sync bug. Tests pass.
///
///   **graham**
///   Thanks — does it need a release?
/// ```
///
/// It is ordinary markdown on purpose: bold text and paragraphs. On GitHub it
/// reads as a signed exchange, a model can write one without knowing anything
/// about this app, and an app that did not recognise the convention would
/// still show every word.
class NoteMessage {
  const NoteMessage({required this.body, this.speaker, this.at});

  /// Who said it, or null for text that came before any signature — an older
  /// note that was never a conversation, kept at the top rather than thrown
  /// away or attributed to someone who did not write it.
  final String? speaker;

  /// When, if the line said. Written in UTC so it sorts and cannot be
  /// misread; shown in local time.
  final DateTime? at;

  final String body;

  bool get isUnsigned => speaker == null;
}

class NoteConversation {
  NoteConversation._();

  /// A line that is only a bold name, and perhaps a time.
  static final _marker =
      RegExp(r'^\s*\*\*([^*\n]{1,60}?)\*\*\s*(?:·\s*(\S+))?\s*$');

  /// Models known to be models, so the app can tell your messages from
  /// theirs without being told who you are.
  static const modelNames = {'claude', 'chatgpt', 'gpt', 'copilot', 'gemini'};

  /// Whether this note is written as a conversation — one signature is
  /// enough, since that is what a first message looks like.
  static bool looksConversational(String notes) {
    return notes.split('\n').any((line) => _marker.hasMatch(line));
  }

  /// The messages in a note, in the order they were written.
  static List<NoteMessage> parse(String notes) {
    final messages = <NoteMessage>[];

    String? speaker;
    DateTime? at;
    final body = <String>[];

    void flush() {
      final text = body.join('\n').trim();
      body.clear();
      if (speaker == null && text.isEmpty) return;
      messages.add(NoteMessage(speaker: speaker, at: at, body: text));
    }

    for (final line in notes.split('\n')) {
      final match = _marker.firstMatch(line);
      if (match == null) {
        body.add(line);
        continue;
      }

      flush();
      speaker = match.group(1)!.trim();
      at = _parseWhen(match.group(2));
    }
    flush();

    return messages;
  }

  /// Adds a message to the end of [notes], returning the new note.
  static String append(
    String notes, {
    required String speaker,
    required String body,
    DateTime? at,
  }) {
    final said = body.trim();
    if (said.isEmpty) return notes;

    final buffer = StringBuffer();
    final existing = notes.trimRight();
    if (existing.isNotEmpty) {
      buffer
        ..write(existing)
        ..write('\n\n');
    }
    buffer
      ..writeln(marker(speaker, at ?? DateTime.now().toUtc()))
      ..write(said);
    return buffer.toString();
  }

  /// The signature line for a message.
  static String marker(String speaker, DateTime at) =>
      '**${speaker.trim()}** · ${formatWhen(at)}';

  /// Minutes are as fine as a conversation needs, and UTC so the file cannot
  /// be misread in another timezone.
  static String formatWhen(DateTime at) {
    final utc = at.toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${utc.year}-${two(utc.month)}-${two(utc.day)}'
        'T${two(utc.hour)}:${two(utc.minute)}Z';
  }

  /// Whether [speaker] is one of the models, so a view can put their messages
  /// on the other side without being told who you are.
  static bool isModel(String? speaker) {
    if (speaker == null) return false;
    return modelNames.contains(speaker.trim().toLowerCase());
  }

  static DateTime? _parseWhen(String? raw) {
    if (raw == null) return null;
    return DateTime.tryParse(raw.trim())?.toUtc();
  }
}
