import 'package:actionnotes/markdown/project_markdown.dart';
import 'package:actionnotes/models/kanban_board.dart';
import 'package:actionnotes/models/project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Kanban columns and filters survive project markdown sync', () {
    final board = Project(slug: 'board', title: 'Board', mode: ProjectMode.kanban);
    final saved = board.copyWith(extraFrontMatter: KanbanBoard.withColumns(board, [
      const KanbanColumn('work', onlyStarred: true),
      const KanbanColumn('home', hideCompleted: false),
    ]));
    final restored = ProjectMarkdown.parse(ProjectMarkdown.serialize(saved),
      slug: 'board');
    final columns = KanbanBoard.columns(restored);
    expect(restored.mode, ProjectMode.kanban);
    expect(columns.map((column) => column.slug), ['work', 'home']);
    expect(columns.first.onlyStarred, isTrue);
    expect(columns.first.hideCompleted, isTrue);
    expect(columns.last.hideCompleted, isFalse);
  });

  test('named filter presets survive project markdown sync', () {
    final board = Project(slug: 'board', title: 'Board', mode: ProjectMode.kanban);
    final saved = board.copyWith(extraFrontMatter: KanbanBoard.withPresets(
      board, {'Focus': [const KanbanColumn('work', onlyStarred: true)]}));
    final restored = ProjectMarkdown.parse(ProjectMarkdown.serialize(saved),
      slug: 'board');
    final preset = KanbanBoard.presets(restored)['Focus'];
    expect(preset, isNotNull);
    expect(preset!.single.slug, 'work');
    expect(preset.single.onlyStarred, isTrue);
  });
}
