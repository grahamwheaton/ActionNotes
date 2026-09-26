import 'dart:convert';

import 'project.dart';

class KanbanColumn {
  const KanbanColumn(this.slug, {this.onlyStarred = false,
    this.hideCompleted = true});

  final String slug;
  final bool onlyStarred;
  final bool hideCompleted;

  KanbanColumn copyWith({bool? onlyStarred, bool? hideCompleted}) =>
      KanbanColumn(slug, onlyStarred: onlyStarred ?? this.onlyStarred,
        hideCompleted: hideCompleted ?? this.hideCompleted);

  Map<String, Object> toJson() => {
    'slug': slug,
    'onlyStarred': onlyStarred,
    'hideCompleted': hideCompleted,
  };
}

class KanbanBoard {
  static const key = 'kanban_columns';

  static List<KanbanColumn> columns(Project board) {
    try {
      final decoded = jsonDecode(board.extraFrontMatter[key] ?? '[]');
      if (decoded is! List) return [];
      return [
        for (final raw in decoded)
          if (raw is Map && raw['slug'] is String)
            KanbanColumn(raw['slug'] as String,
              onlyStarred: raw['onlyStarred'] == true,
              hideCompleted: raw['hideCompleted'] != false),
      ];
    } on FormatException {
      return [];
    }
  }

  static Map<String, String> withColumns(Project board,
      List<KanbanColumn> columns) => {
    ...board.extraFrontMatter,
    key: jsonEncode(columns.map((column) => column.toJson()).toList()),
  };
}
