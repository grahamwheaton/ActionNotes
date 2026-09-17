import 'package:actionnotes/markdown/item_tags.dart';
import 'package:actionnotes/models/checklist_item.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parse', () {
    test('reads bracketed words as tags, in the order written', () {
      expect(ItemTags.parse('Fix the sync [bug] [app]'), ['bug', 'app']);
    });

    test('a tag can be more than one word', () {
      expect(ItemTags.parse('Book the van [next week]'), ['next week']);
    });

    test('the same tag twice is one tag, keeping the first spelling', () {
      expect(ItemTags.parse('[Bug] and again [bug]'), ['Bug']);
    });

    test('an empty pair of brackets is not a tag', () {
      expect(ItemTags.parse('Nothing here [] or [  ]'), isEmpty);
    });

    // `[tag]` is a fragment of link syntax, so the two things it could be
    // mistaken for are worth pinning down.
    test('a link label is not a tag', () {
      expect(ItemTags.parse('Read [the docs](https://example.com)'), isEmpty);
      expect(ItemTags.parse('![a picture](pic.png)'), isEmpty);
    });

    test('a wikilink is not a tag', () {
      expect(ItemTags.parse('See [[Shopping]]'), isEmpty);
    });

    test('a tag beside a link is still read', () {
      expect(
        ItemTags.parse('Read [the docs](https://example.com) [work]'),
        ['work'],
      );
    });

    test('a tag cannot span lines', () {
      expect(ItemTags.parse('Open [bracket\nclosed]'), isEmpty);
    });
  });

  group('strip', () {
    test('leaves the title without its markers', () {
      expect(ItemTags.strip('Fix the sync [bug]'), 'Fix the sync');
    });

    test('closes the gap a tag in the middle leaves', () {
      expect(ItemTags.strip('Fix [bug] the sync'), 'Fix the sync');
    });

    test('an item that is only tags has no title left', () {
      expect(ItemTags.strip('[bug] [app]'), '');
    });

    test('a link survives stripping', () {
      expect(
        ItemTags.strip('Read [the docs](https://example.com) [work]'),
        'Read [the docs](https://example.com)',
      );
    });
  });

  group('has', () {
    test('matches a tag whatever its case', () {
      expect(ItemTags.has('Fix it [Bug]', 'bug'), isTrue);
    });

    test('does not match part of a longer tag', () {
      expect(ItemTags.has('Book it [appointments]', 'app'), isFalse);
    });

    test('does not match the same word outside a tag', () {
      expect(ItemTags.has('Fix the bug', 'bug'), isFalse);
    });
  });

  group('queryTag', () {
    test('a bracketed query names a tag', () {
      expect(ItemTags.queryTag('[bug]'), 'bug');
      expect(ItemTags.queryTag('  [next week] '), 'next week');
    });

    test('ordinary text does not', () {
      expect(ItemTags.queryTag('bug'), isNull);
      expect(ItemTags.queryTag('fix [bug]'), isNull);
      expect(ItemTags.queryTag('[]'), isNull);
    });
  });

  test('an item carries its own tags and a title without them', () {
    const item = ChecklistItem(text: 'Fix the sync [bug] [app]');

    expect(item.tags, ['bug', 'app']);
    expect(item.title, 'Fix the sync');
    // The markers stay in the text, which is what the file holds.
    expect(item.text, 'Fix the sync [bug] [app]');
  });
}
