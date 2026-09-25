import 'package:actionnotes/models/checklist_item.dart';
import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/state/search.dart';
import 'package:flutter_test/flutter_test.dart';

final projects = [
  Project(
    slug: 'house-move',
    title: 'House move',
    items: const [
      ChecklistItem(text: 'Book the van'),
      ChecklistItem(text: 'Cancel broadband', notes: 'Rang them on Tuesday.'),
    ],
    notes: "Landlord's number is in the drawer.",
  ),
  Project(
    slug: 'groceries',
    title: 'Groceries',
    items: const [ChecklistItem(text: 'Milk')],
  ),
];

void main() {
  test('an empty query matches nothing', () {
    expect(ProjectSearch.run(projects, ''), isEmpty);
    expect(ProjectSearch.run(projects, '   '), isEmpty);
  });

  test('matches a project title', () {
    final hits = ProjectSearch.run(projects, 'house');

    expect(hits.single.field, SearchField.projectTitle);
    expect(hits.single.project.slug, 'house-move');
    expect(hits.single.itemIndex, isNull);
  });

  test('matches an item and says which one', () {
    final hits = ProjectSearch.run(projects, 'van');

    expect(hits.single.field, SearchField.itemText);
    expect(hits.single.itemIndex, 0);
    expect(hits.single.text, 'Book the van');
  });

  test('matches inside an item note, reporting just that line', () {
    final hits = ProjectSearch.run(projects, 'tuesday');

    expect(hits.single.field, SearchField.itemNotes);
    expect(hits.single.itemIndex, 1);
    expect(hits.single.text, 'Rang them on Tuesday.');
  });

  test('matches a project note', () {
    final hits = ProjectSearch.run(projects, 'drawer');

    expect(hits.single.field, SearchField.projectNotes);
    expect(hits.single.itemIndex, isNull);
  });

  test('ignores case', () {
    expect(ProjectSearch.run(projects, 'MILK'), hasLength(1));
    expect(ProjectSearch.run(projects, 'milk'), hasLength(1));
  });

  test('an item matching by text is not also reported by its note', () {
    final one = Project(
      slug: 'p',
      title: 'P',
      items: const [ChecklistItem(text: 'doors', notes: 'about doors')],
    );

    expect(ProjectSearch.run([one], 'doors'), hasLength(1));
  });

  test('reports a hit per match across projects', () {
    final hits = ProjectSearch.run(projects, 'o');

    expect(hits.length, greaterThan(1));
    expect(hits.map((h) => h.project.slug).toSet(), contains('house-move'));
  });

  test('a note reports its first matching line only', () {
    final one = Project(
      slug: 'p',
      title: 'P',
      items: const [
        ChecklistItem(text: 'x', notes: 'first hit here\nsecond hit here'),
      ],
    );

    final hits = ProjectSearch.run([one], 'hit');

    expect(hits, hasLength(1));
    expect(hits.single.text, 'first hit here');
  });

  test('nothing matches an absent term', () {
    expect(ProjectSearch.run(projects, 'zebra'), isEmpty);
  });

  test('tags in note sections appear in the tag index and search', () {
    final project = Project(slug: 'notes', title: 'Notes', blocks: const [
      ProjectBlock(title: 'Ideas', body: 'A useful [canvas] thought\n- [ ] task'),
    ]);
    expect(ProjectSearch.tags([project]).map((entry) => entry.tag), ['canvas']);
    final hit = ProjectSearch.run([project], '[canvas]').single;
    expect(hit.field, SearchField.blockNotes);
    expect(hit.blockTitle, 'Ideas');
    expect(ProjectSearch.run([project], 'useful').single.field,
        SearchField.blockNotes);
  });
}
