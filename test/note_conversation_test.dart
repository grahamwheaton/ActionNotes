import 'package:actionnotes/markdown/note_conversation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('reading a note as a conversation', () {
    test('a signed paragraph is a message', () {
      const notes = '**Claude** · 2026-09-18T09:12Z\n'
          'Fixed the sync bug.\n'
          '\n'
          '**graham**\n'
          'Thanks.';

      final messages = NoteConversation.parse(notes);

      expect(messages, hasLength(2));
      expect(messages.first.speaker, 'Claude');
      expect(messages.first.body, 'Fixed the sync bug.');
      expect(messages.first.at, DateTime.utc(2026, 9, 18, 9, 12));
      expect(messages.last.speaker, 'graham');
      expect(messages.last.at, isNull);
    });

    test('a message can hold several paragraphs, and markdown', () {
      const notes = '**Claude** · 2026-09-18T09:12Z\n'
          'First line.\n'
          '\n'
          '- a bullet\n'
          '- another\n';

      final single = NoteConversation.parse(notes).single;

      expect(single.body, 'First line.\n\n- a bullet\n- another');
    });

    // An older note was never a conversation. Its text is kept as it is,
    // attributed to nobody, rather than being thrown away or credited to
    // whoever happens to write next.
    test('text before the first signature belongs to no one', () {
      const notes = 'Just an ordinary note.\n\n'
          '**Claude** · 2026-09-18T09:12Z\n'
          'And a reply.';

      final messages = NoteConversation.parse(notes);

      expect(messages.first.isUnsigned, isTrue);
      expect(messages.first.body, 'Just an ordinary note.');
      expect(messages.last.speaker, 'Claude');
    });

    test('a plain note is one unsigned message', () {
      final messages = NoteConversation.parse('Nothing conversational here.');

      expect(messages.single.isUnsigned, isTrue);
      expect(NoteConversation.looksConversational('Nothing here.'), isFalse);
    });

    test('one signature is enough to call it a conversation', () {
      expect(
        NoteConversation.looksConversational('**Claude**\nHello'),
        isTrue,
      );
    });

    // Bold is used in ordinary prose too, so only a line that is nothing but
    // a name counts.
    test('bold in the middle of a line is not a signature', () {
      const notes = 'This is **important** and not a signature.';

      expect(NoteConversation.looksConversational(notes), isFalse);
      expect(NoteConversation.parse(notes).single.isUnsigned, isTrue);
    });

    test('a bold line of prose is not a signature either', () {
      const notes = '**This is a whole sentence in bold, not a name at all**';

      expect(NoteConversation.looksConversational(notes), isTrue);
      // It is 60 characters or fewer, so it does read as a name — the trade
      // for keeping the marker simple. The text is still all there.
      expect(NoteConversation.parse(notes).single.speaker, isNotNull);
    });

    test('an empty note has no messages', () {
      expect(NoteConversation.parse(''), isEmpty);
      expect(NoteConversation.parse('   \n\n  '), isEmpty);
    });
  });

  group('adding a message', () {
    test('appends it with a signature', () {
      final notes = NoteConversation.append(
        '',
        speaker: 'graham',
        body: 'First thought',
        at: DateTime.utc(2026, 9, 18, 9, 30),
      );

      expect(notes, '**graham** · 2026-09-18T09:30Z\nFirst thought');
    });

    test('keeps what was there, conversation or not', () {
      final notes = NoteConversation.append(
        'An older plain note.',
        speaker: 'graham',
        body: 'A reply to myself',
        at: DateTime.utc(2026, 9, 18, 9, 30),
      );

      expect(
        notes,
        'An older plain note.\n\n'
        '**graham** · 2026-09-18T09:30Z\n'
        'A reply to myself',
      );
      // And reads back as two messages, the first unsigned.
      final messages = NoteConversation.parse(notes);
      expect(messages.first.isUnsigned, isTrue);
      expect(messages.last.speaker, 'graham');
    });

    test('nothing is added for an empty message', () {
      expect(NoteConversation.append('kept', speaker: 'g', body: '   '), 'kept');
    });

    test('a message survives a round trip', () {
      var notes = '';
      for (final said in ['one', 'two', 'three']) {
        notes = NoteConversation.append(
          notes,
          speaker: said == 'two' ? 'Claude' : 'graham',
          body: said,
          at: DateTime.utc(2026, 9, 18, 9, 30),
        );
      }

      final messages = NoteConversation.parse(notes);
      expect(messages.map((m) => m.body), ['one', 'two', 'three']);
      expect(messages.map((m) => m.speaker), ['graham', 'Claude', 'graham']);
    });
  });

  group('telling the sides apart', () {
    test('the models are known by name, whatever the case', () {
      expect(NoteConversation.isModel('Claude'), isTrue);
      expect(NoteConversation.isModel('chatgpt'), isTrue);
      expect(NoteConversation.isModel('ChatGPT'), isTrue);
      expect(NoteConversation.isModel('graham'), isFalse);
      expect(NoteConversation.isModel(null), isFalse);
    });
  });

  test('times are written in UTC, to the minute', () {
    expect(
      NoteConversation.formatWhen(DateTime.utc(2026, 1, 2, 3, 4, 55)),
      '2026-01-02T03:04Z',
    );
  });
}
