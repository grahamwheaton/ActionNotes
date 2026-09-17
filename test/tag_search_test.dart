import 'package:actionnotes/markdown/project_markdown.dart';
import 'package:actionnotes/models/checklist_item.dart';
import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/state/search.dart';
import 'package:flutter_test/flutter_test.dart';

Project project(String title, List<ChecklistItem> items) => Project(
      slug: title.toLowerCase(),
      title: title,
      items: items,
    );

final projects = [
  project('Work', const [
    ChecklistItem(text: 'Fix the sync [bug]'),
    ChecklistItem(text: 'Book the van [appointments]'),
    ChecklistItem(text: 'Chase the invoice', notes: 'mentions a bug'),
  ]),
  project('Home', const [
    ChecklistItem(text: 'Mend the gate [diy] [Bug]'),
  ]),
];

void main() {
  test('a bracketed query finds everything carrying that tag', () {
    final hits = ProjectSearch.run(projects, '[bug]');

    expect(hits.map((hit) => hit.text), [
      'Fix the sync [bug]',
      'Mend the gate [diy] [Bug]',
    ]);
    expect(hits.first.project.title, 'Work');
    expect(hits.last.project.title, 'Home');
  });

  test('a tag query is an exact match, not a substring one', () {
    expect(ProjectSearch.run(projects, '[app]'), isEmpty);
    expect(
      ProjectSearch.run(projects, '[appointments]').single.text,
      'Book the van [appointments]',
    );
  });

  // The pill sends `[bug]`; typing `bug` should still behave as it always
  // has, which includes matching notes and the middle of words.
  test('the same word unbracketed is still an ordinary search', () {
    final hits = ProjectSearch.run(projects, 'bug');

    expect(hits.map((hit) => hit.field), [
      SearchField.itemText,
      SearchField.itemNotes,
      SearchField.itemText,
    ]);
  });

  test('a tag nothing carries finds nothing, rather than everything', () {
    expect(ProjectSearch.run(projects, '[nope]'), isEmpty);
  });

  // A tag at the very start sits where the checkbox marker was, which is the
  // one position that could be misread on the way back in.
  test('a tag written first survives a round trip', () {
    final saved = ProjectMarkdown.serialize(
      project('Work', const [ChecklistItem(text: '[bug] fix the sync')]),
    );
    final read = ProjectMarkdown.parse(saved, slug: 'work');

    expect(read.items.single.text, '[bug] fix the sync');
    expect(read.items.single.tags, ['bug']);
    expect(read.items.single.title, 'fix the sync');
    expect(read.items.single.done, isFalse);
  });

  test('tags survive a round trip through the markdown', () {
    final saved = ProjectMarkdown.serialize(projects.first);
    final read = ProjectMarkdown.parse(saved, slug: 'work');

    expect(read.items.first.text, 'Fix the sync [bug]');
    expect(read.items.first.tags, ['bug']);
    expect(ProjectSearch.run([read], '[bug]'), hasLength(1));
  });
}
