/// Reading and writing the day a feed's section stands for.
///
/// A feed is an ordinary project whose `##` sections happen to be dates, so
/// the whole of the format is "what does this heading's date say". Kept apart
/// from the view because it is arithmetic about dates and can be reasoned
/// about without a screen — which for anything involving dates is worth the
/// separation on its own.
class FeedDays {
  FeedDays._();

  /// `2026-09-20`, which sorts as a string in the same order it sorts as a
  /// date and is the one date format nobody has to be told how to read.
  static String titleFor(DateTime day) {
    final local = DateTime(day.year, day.month, day.day);
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  /// The day a section heading stands for, or null when it is not a date.
  ///
  /// Lenient about what surrounds it, so a heading someone has written as
  /// `2026-09-20 — Thursday` on GitHub is still that day rather than being
  /// dropped out of the feed for having a note after it.
  static DateTime? dayOf(String title) {
    final match = RegExp(r'(\d{4})-(\d{2})-(\d{2})').firstMatch(title.trim());
    if (match == null) return null;

    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;

    final date = DateTime(year, month, day);
    // Rejects the 31st of a month with thirty days, which DateTime would
    // otherwise roll forward into the next one without complaint.
    if (date.month != month || date.day != day) return null;
    return date;
  }

  static bool isDay(String title) => dayOf(title) != null;

  /// The days a feed holds, newest first.
  ///
  /// Sections that are not dates keep their place at the end rather than
  /// being hidden: a feed someone has added an ordinary heading to should
  /// still show that heading, not quietly swallow what is under it.
  static List<String> order(Iterable<String> titles) {
    final dated = <String>[];
    final rest = <String>[];

    for (final title in titles) {
      (isDay(title) ? dated : rest).add(title);
    }
    dated.sort((a, b) => dayOf(b)!.compareTo(dayOf(a)!));
    return [...dated, ...rest];
  }

  /// How a day reads to a person: Today and Yesterday by name, the rest by
  /// their date, and the year left off within the current one.
  static String label(String title, {DateTime? now}) {
    final day = dayOf(title);
    if (day == null) return title;

    final today = _startOfDay(now ?? DateTime.now());
    final difference = today.difference(day).inDays;

    if (difference == 0) return 'Today';
    if (difference == 1) return 'Yesterday';

    final month = _months[day.month - 1];
    return day.year == today.year
        ? '${day.day} $month'
        : '${day.day} $month ${day.year}';
  }

  /// Whether a day should open by itself: today's writing is what you came
  /// to read, and everything before it is folded until asked for.
  static bool opensByDefault(String title, {DateTime? now}) {
    final day = dayOf(title);
    if (day == null) return true;
    return day == _startOfDay(now ?? DateTime.now());
  }

  static DateTime _startOfDay(DateTime at) =>
      DateTime(at.year, at.month, at.day);

  static const _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
}
