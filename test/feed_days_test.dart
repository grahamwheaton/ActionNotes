import 'package:actionnotes/markdown/feed_days.dart';
import 'package:actionnotes/models/project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the day a heading stands for', () {
    test('a plain date is that day', () {
      expect(FeedDays.dayOf('2026-09-20'), DateTime(2026, 9, 20));
      expect(FeedDays.isDay('2026-09-20'), isTrue);
    });

    test('a date with something written after it still counts', () {
      // Someone writing the file by hand on GitHub would do this, and
      // dropping the day for it would hide everything under it.
      expect(FeedDays.dayOf('2026-09-20 — Thursday'), DateTime(2026, 9, 20));
      expect(FeedDays.dayOf('  2026-09-20  '), DateTime(2026, 9, 20));
    });

    test('a heading that is not a date is not a day', () {
      expect(FeedDays.dayOf('Ideas'), isNull);
      expect(FeedDays.dayOf(''), isNull);
      expect(FeedDays.isDay('Shopping'), isFalse);
    });

    test('a date that never happened is not a day', () {
      // DateTime would roll both of these into the following month without
      // complaining, which would file writing under a day nobody chose.
      expect(FeedDays.dayOf('2026-02-31'), isNull);
      expect(FeedDays.dayOf('2026-04-31'), isNull);
      expect(FeedDays.dayOf('2026-13-01'), isNull);
      // But a real leap day is real.
      expect(FeedDays.dayOf('2028-02-29'), DateTime(2028, 2, 29));
    });

    test('a day is written the one way nobody has to be told how to read', () {
      expect(FeedDays.titleFor(DateTime(2026, 9, 20, 14, 30)), '2026-09-20');
      expect(FeedDays.titleFor(DateTime(2026, 1, 5)), '2026-01-05');
    });

    test('written and read back is the same day', () {
      final day = DateTime(2026, 3, 7);
      expect(FeedDays.dayOf(FeedDays.titleFor(day)), day);
    });
  });

  group('the order days come in', () {
    test('newest first, which is where today is', () {
      expect(FeedDays.order(['2026-09-18', '2026-09-20', '2026-09-19']), [
        '2026-09-20',
        '2026-09-19',
        '2026-09-18',
      ]);
    });

    test('a heading that is not a date keeps its place at the end', () {
      // Rather than being hidden: a feed someone has added an ordinary
      // heading to should still show it, not swallow what is under it.
      expect(FeedDays.order(['Ideas', '2026-09-18', '2026-09-20']), [
        '2026-09-20',
        '2026-09-18',
        'Ideas',
      ]);
    });

    test('nothing at all is nothing, not an error', () {
      expect(FeedDays.order(const []), isEmpty);
    });
  });

  group('what a day is called', () {
    final now = DateTime(2026, 9, 20);

    test('today and yesterday are named, not dated', () {
      expect(FeedDays.label('2026-09-20', now: now), 'Today');
      expect(FeedDays.label('2026-09-19', now: now), 'Yesterday');
    });

    test('this year leaves the year off, other years keep it', () {
      expect(FeedDays.label('2026-09-14', now: now), '14 September');
      expect(FeedDays.label('2025-12-24', now: now), '24 December 2025');
    });

    test('a heading that is not a date is left exactly as written', () {
      expect(FeedDays.label('Ideas', now: now), 'Ideas');
    });
  });

  group('which days open by themselves', () {
    final now = DateTime(2026, 9, 20, 9, 30);

    test('today does, because it is what you came to read', () {
      expect(FeedDays.opensByDefault('2026-09-20', now: now), isTrue);
    });

    test('every day before it is folded until asked for', () {
      expect(FeedDays.opensByDefault('2026-09-19', now: now), isFalse);
      expect(FeedDays.opensByDefault('2025-01-01', now: now), isFalse);
    });

    test('a heading that is not a day is left open', () {
      expect(FeedDays.opensByDefault('Ideas', now: now), isTrue);
    });
  });

  group('the mode in the file', () {
    test('a feed says so, and reads back', () {
      expect(ProjectMode.parse('feed'), ProjectMode.feed);
      expect(ProjectMode.feed.name, 'feed');
    });

    test('anything unrecognised is still a checklist', () {
      expect(ProjectMode.parse('nonsense'), ProjectMode.tasks);
      expect(ProjectMode.parse(null), ProjectMode.tasks);
    });
  });
}
