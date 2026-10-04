import 'project.dart';

enum ProjectSort {
  recent('Recent'), alphabetical('Alphabetical'), stars('Stars');
  const ProjectSort(this.label);
  final String label;

  List<Project> sorted(Iterable<Project> projects) {
    final result = projects.toList();
    result.sort((a, b) {
      final order = switch (this) {
        ProjectSort.recent => (b.updated ?? b.created ?? DateTime(1970))
            .compareTo(a.updated ?? a.created ?? DateTime(1970)),
        ProjectSort.stars => b.items.where((item) => item.starred).length
            .compareTo(a.items.where((item) => item.starred).length),
        ProjectSort.alphabetical => 0,
      };
      if (order != 0) return order;
      final title = a.title.toLowerCase().compareTo(b.title.toLowerCase());
      return title != 0 ? title : a.slug.compareTo(b.slug);
    });
    return result;
  }
}

double _number(Map<String, dynamic> json, String key, double fallback,
    double min, double max) {
  final value = json[key];
  return value is num && value.isFinite
      ? value.toDouble().clamp(min, max).toDouble() : fallback;
}

class NoteFormatting {
  const NoteFormatting({this.horizontalMargin = 32, this.verticalMargin = 24,
    this.fontSize = 15.5, this.lineHeight = 1.6, this.paragraphSpacing = 10,
    this.headingScale = 1, this.font = 'System'});

  final double horizontalMargin, verticalMargin, fontSize, lineHeight,
      paragraphSpacing, headingScale;
  final String font;
  String? get fontFamily => switch (font) {
    'Serif' => 'serif', 'Monospace' => 'monospace', _ => null,
  };
  List<String>? get fontFallback => switch (font) {
    'Serif' => const ['Georgia', 'Noto Serif'],
    'Monospace' => const ['Consolas', 'Courier New'], _ => null,
  };

  NoteFormatting copyWith({double? horizontalMargin, double? verticalMargin,
    double? fontSize, double? lineHeight, double? paragraphSpacing,
    double? headingScale, String? font}) => NoteFormatting(
    horizontalMargin: horizontalMargin ?? this.horizontalMargin,
    verticalMargin: verticalMargin ?? this.verticalMargin,
    fontSize: fontSize ?? this.fontSize, lineHeight: lineHeight ?? this.lineHeight,
    paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
    headingScale: headingScale ?? this.headingScale, font: font ?? this.font,
  );

  Map<String, dynamic> toJson() => {
    'horizontalMargin': horizontalMargin, 'verticalMargin': verticalMargin,
    'fontSize': fontSize, 'lineHeight': lineHeight,
    'paragraphSpacing': paragraphSpacing, 'headingScale': headingScale,
    'font': font,
  };

  factory NoteFormatting.fromJson(Map<String, dynamic> json) => NoteFormatting(
    horizontalMargin: _number(json, 'horizontalMargin', 32, 0, 80),
    verticalMargin: _number(json, 'verticalMargin', 24, 0, 80),
    fontSize: _number(json, 'fontSize', 15.5, 12, 26),
    lineHeight: _number(json, 'lineHeight', 1.6, 1.1, 2.2),
    paragraphSpacing: _number(json, 'paragraphSpacing', 10, 0, 24),
    headingScale: _number(json, 'headingScale', 1, .8, 1.6),
    font: ['System', 'Serif', 'Monospace'].contains(json['font'])
        ? json['font'] as String : 'System',
  );
}

class ViewPreferences {
  const ViewPreferences({this.sidebarWidth = 280,
    this.projectSort = ProjectSort.recent,
    this.formatting = const NoteFormatting()});
  final double sidebarWidth;
  final ProjectSort projectSort;
  final NoteFormatting formatting;

  ViewPreferences copyWith({double? sidebarWidth, ProjectSort? projectSort,
    NoteFormatting? formatting}) => ViewPreferences(
    sidebarWidth: sidebarWidth ?? this.sidebarWidth,
    projectSort: projectSort ?? this.projectSort,
    formatting: formatting ?? this.formatting,
  );

  Map<String, dynamic> toJson() => {
    'sidebarWidth': sidebarWidth, 'projectSort': projectSort.name,
    'formatting': formatting.toJson(),
  };

  factory ViewPreferences.fromJson(Map<String, dynamic> json) => ViewPreferences(
    sidebarWidth: _number(json, 'sidebarWidth', 280, 220, 600),
    projectSort: ProjectSort.values.where((sort) => sort.name == json['projectSort'])
        .firstOrNull ?? ProjectSort.recent,
    formatting: json['formatting'] is Map<String, dynamic>
        ? NoteFormatting.fromJson(json['formatting'] as Map<String, dynamic>)
        : const NoteFormatting(),
  );
}
