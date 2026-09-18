import 'package:actionnotes/markdown/mentions.dart';
import 'package:actionnotes/models/checklist_item.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('reading mentions', () {
    test('finds a name after an at sign', () {
      expect(Mentions.parse('@Claude pick this up'), ['Claude']);
      expect(Mentions.parse('ask @ChatGPT about it'), ['ChatGPT']);
    });

    test('finds several, each once', () {
      expect(
        Mentions.parse('@Claude and @ChatGPT and @claude again'),
        ['Claude', 'ChatGPT'],
      );
    });

    // An email address is the obvious false positive.
    test('an email address is not a mention', () {
      expect(Mentions.parse('mail graham@example.com about it'), isEmpty);
    });

    test('sentence punctuation is not part of the name', () {
      expect(Mentions.parse('over to you @Claude.'), ['Claude']);
    });

    test('a bare at sign is nothing', () {
      expect(Mentions.parse('costs 5 @ each'), isEmpty);
      expect(Mentions.parse('@'), isEmpty);
      expect(Mentions.parse('@@claude'), isEmpty);
    });

    test('matching a name ignores case and a leading at', () {
      expect(Mentions.mentions('@Claude look', 'claude'), isTrue);
      expect(Mentions.mentions('@Claude look', '@CLAUDE'), isTrue);
      expect(Mentions.mentions('@Claude look', 'chatgpt'), isFalse);
    });
  });

  group('a search for a name', () {
    test('a bare @name asks for a mention', () {
      expect(Mentions.queryName('@claude'), 'claude');
      expect(Mentions.queryName('  @Claude '), 'Claude');
    });

    test('anything else is an ordinary search', () {
      expect(Mentions.queryName('claude'), isNull);
      expect(Mentions.queryName('@claude please'), isNull);
      expect(Mentions.queryName('graham@example.com'), isNull);
    });
  });

  group('who an item is waiting on', () {
    test('a mention with no reply is waiting', () {
      expect(
        Mentions.awaiting(text: '@Claude pick this up', notes: ''),
        ['Claude'],
      );
    });

    test('nothing is waiting without a mention', () {
      expect(Mentions.awaiting(text: 'Ordinary item', notes: 'a note'), isEmpty);
    });

    // Answering is replying, not editing the mention away — which matters
    // when the other party has been told not to delete anything.
    test('a reply from that name answers it', () {
      const notes = '**Claude** · 2026-09-18T09:12Z\nPicked it up, done.';

      expect(Mentions.awaiting(text: '@Claude have a look', notes: notes),
          isEmpty);
    });

    test('a reply from someone else does not', () {
      const notes = '**graham** · 2026-09-18T09:12Z\nAny thoughts?';

      expect(
        Mentions.awaiting(text: '@Claude have a look', notes: notes),
        ['Claude'],
      );
    });

    test('asking again after a reply waits again', () {
      const notes = '**Claude** · 2026-09-18T09:12Z\nDone.\n\n'
          '**graham** · 2026-09-18T09:20Z\n@Claude one more thing';

      expect(Mentions.awaiting(text: 'Item', notes: notes), ['Claude']);
    });

    test('two names, one answered', () {
      const notes = '**Claude** · 2026-09-18T09:12Z\nMy half is done.';

      expect(
        Mentions.awaiting(text: '@Claude @ChatGPT both of you', notes: notes),
        ['ChatGPT'],
      );
    });

    test('a mention written in the notes counts too', () {
      expect(
        Mentions.awaiting(text: 'Item', notes: 'thinking aloud, @Claude?'),
        ['Claude'],
      );
    });

    test('an item knows who it waits on', () {
      const item = ChecklistItem(
        text: 'Fix the sync @Claude',
        notes: '**graham**\nwhen you get a minute',
      );

      expect(item.awaiting, ['Claude']);
      expect(item.mentions, ['Claude']);
    });
  });
}
