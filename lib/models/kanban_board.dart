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
  static const presetsKey = 'kanban_presets';

  static List<KanbanColumn> _decodeColumns(Object? decoded) {
    if (decoded is! List) return [];
    return [
      for (final raw in decoded)
        if (raw is Map && raw['slug'] is String)
          KanbanColumn(raw['slug'] as String,
            onlyStarred: raw['onlyStarred'] == true,
            hideCompleted: raw['hideCompleted'] != false),
    ];
  }

  static List<KanbanColumn> columns(Project board) {
    try {
      return _decodeColumns(jsonDecode(board.extraFrontMatter[key] ?? '[]'));
    } on FormatException {
      return [];
    }
  }

  static Map<String, String> withColumns(Project board,
      List<KanbanColumn> columns) => {
    ...board.extraFrontMatter,
    key: jsonEncode(columns.map((column) => column.toJson()).toList()),
  };

  static Map<String, List<KanbanColumn>> presets(Project board) {
    try {
      final decoded = jsonDecode(board.extraFrontMatter[presetsKey] ?? '{}');
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String)
            entry.key as String: _decodeColumns(entry.value),
      };
    } on FormatException {
      return {};
    }
  }

  static Map<String, String> withPresets(Project board,
      Map<String, List<KanbanColumn>> presets) => {
    ...board.extraFrontMatter,
    presetsKey: jsonEncode({
      for (final entry in presets.entries)
        entry.key: [for (final column in entry.value) column.toJson()],
    }),
  };
}
