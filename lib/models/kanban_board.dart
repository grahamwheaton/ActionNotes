import 'dart:convert';

import 'project.dart';

class KanbanColumn {
  const KanbanColumn(this.slug, {this.onlyStarred = false,
    this.hideCompleted = true, this.color});

  final String slug;
  final bool onlyStarred;
  final bool hideCompleted;

  /// The panel's own colour as 0xAARRGGBB, or null for the theme's.
  final int? color;

  KanbanColumn copyWith({bool? onlyStarred, bool? hideCompleted, int? color,
      bool clearColor = false}) =>
      KanbanColumn(slug, onlyStarred: onlyStarred ?? this.onlyStarred,
        hideCompleted: hideCompleted ?? this.hideCompleted,
        color: clearColor ? null : color ?? this.color);

  Map<String, Object> toJson() => {
    'slug': slug,
    'onlyStarred': onlyStarred,
    'hideCompleted': hideCompleted,
    if (color != null) 'color': color!,
  };
}

/// One size for every column on a board, so resizing one resizes them all.
/// A null height means the columns fill the screen.
class KanbanSize {
  const KanbanSize({this.width = defaultWidth, this.height});

  static const defaultWidth = 280.0;
  static const minWidth = 180.0;
  static const maxWidth = 640.0;
  static const minHeight = 160.0;

  final double width;
  final double? height;

  Map<String, Object> toJson() => {
    'width': width,
    if (height != null) 'height': height!,
  };
}

class KanbanBoard {
  static const key = 'kanban_columns';
  static const presetsKey = 'kanban_presets';
  static const sizeKey = 'kanban_size';

  static KanbanSize size(Project board) {
    try {
      final decoded = jsonDecode(board.extraFrontMatter[sizeKey] ?? '{}');
      if (decoded is! Map) return const KanbanSize();
      final width = decoded['width'];
      final height = decoded['height'];
      return KanbanSize(
        width: width is num
            ? width.toDouble().clamp(KanbanSize.minWidth, KanbanSize.maxWidth)
            : KanbanSize.defaultWidth,
        height: height is num
            ? height.toDouble().clamp(KanbanSize.minHeight, 4000.0)
            : null,
      );
    } on FormatException {
      return const KanbanSize();
    }
  }

  static Map<String, String> withSize(Project board, KanbanSize size) => {
    ...board.extraFrontMatter,
    sizeKey: jsonEncode(size.toJson()),
  };

  static List<KanbanColumn> _decodeColumns(Object? decoded) {
    if (decoded is! List) return [];
    return [
      for (final raw in decoded)
        if (raw is Map && raw['slug'] is String)
          KanbanColumn(raw['slug'] as String,
            onlyStarred: raw['onlyStarred'] == true,
            hideCompleted: raw['hideCompleted'] != false,
            color: raw['color'] is int ? raw['color'] as int : null),
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
