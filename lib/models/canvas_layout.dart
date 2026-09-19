import 'dart:convert';

/// Where one card sits on a canvas.
class CanvasSpot {
  const CanvasSpot({
    required this.x,
    required this.y,
    this.width = 260,
    this.z = 0,
    this.ref = '',
    this.rotation = 0,
    this.flipX = false,
    this.flipY = false,
    this.locked = false,
  });

  final double x;
  final double y;

  /// How wide the card is drawn. Height follows the picture, or the text.
  final double width;

  /// Stacking order. Higher is nearer the front.
  final int z;

  /// What the card was when this position was written, so a position can find
  /// its card again when the list has shifted under it.
  final String ref;

  /// Degrees clockwise about the card's own centre.
  final double rotation;

  /// Mirrored left to right, or top to bottom.
  final bool flipX;
  final bool flipY;

  /// Held in place: it can be seen and selected but not moved, resized or
  /// turned, so a background sheet stays put while things are arranged on it.
  final bool locked;

  CanvasSpot copyWith({
    double? x,
    double? y,
    double? width,
    int? z,
    String? ref,
    double? rotation,
    bool? flipX,
    bool? flipY,
    bool? locked,
  }) => CanvasSpot(
    x: x ?? this.x,
    y: y ?? this.y,
    width: width ?? this.width,
    z: z ?? this.z,
    ref: ref ?? this.ref,
    rotation: rotation ?? this.rotation,
    flipX: flipX ?? this.flipX,
    flipY: flipY ?? this.flipY,
    locked: locked ?? this.locked,
  );

  // Written only when it is not the default, so a card nobody has turned or
  // mirrored keeps the small entry it always had.
  Map<String, dynamic> toJson() => {
    'x': x,
    'y': y,
    'w': width,
    'z': z,
    if (ref.isNotEmpty) 'ref': ref,
    if (rotation != 0) 'r': rotation,
    if (flipX) 'fx': true,
    if (flipY) 'fy': true,
    if (locked) 'lock': true,
  };

  static CanvasSpot fromJson(Map<String, dynamic> json) => CanvasSpot(
    x: _number(json['x']),
    y: _number(json['y']),
    width: json.containsKey('w') ? _number(json['w']) : 260,
    z: _number(json['z']).round(),
    ref: json['ref'] as String? ?? '',
    rotation: json.containsKey('r') ? _number(json['r']) : 0,
    flipX: json['fx'] == true,
    flipY: json['fy'] == true,
    locked: json['lock'] == true,
  );

  static double _number(Object? value) => switch (value) {
    final num n => n.toDouble(),
    final String s => double.tryParse(s) ?? 0,
    _ => 0,
  };

  @override
  bool operator ==(Object other) =>
      other is CanvasSpot &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.z == z &&
      other.ref == ref &&
      other.rotation == rotation &&
      other.flipX == flipX &&
      other.flipY == flipY &&
      other.locked == locked;

  @override
  int get hashCode =>
      Object.hash(x, y, width, z, ref, rotation, flipX, flipY, locked);
}

/// Where everything on one project's canvases sits.
///
/// Kept beside the project rather than in it, in `canvas/<slug>.json`. A
/// canvas needs an x, a y, a width and a stacking order for everything on it,
/// and none of that is readable markdown — writing it into the project file
/// would turn a file anyone can read into a blob with co-ordinates in it.
///
/// So the markdown keeps the content and this keeps only the arrangement.
/// Losing this file costs the layout and nothing else: the canvas reads back
/// as the list of pictures and notes it always was. Losing the layout is
/// survivable; losing the content is not.
///
/// Which sections are canvases is also recorded here, for the same reason —
/// it is the one fact about a canvas that has nowhere sensible to live in
/// markdown, and keeping it here means a project with no layout file has no
/// canvases and simply shows its sections as notes.
class CanvasLayout {
  const CanvasLayout({this.sections = const {}, this.sha});

  /// Section title to the spots of its cards, in the order the cards are in
  /// the file.
  final Map<String, List<CanvasSpot>> sections;

  /// The blob SHA GitHub last gave us for the layout file.
  final String? sha;

  static const empty = CanvasLayout();

  bool get isEmpty => sections.isEmpty;

  bool isCanvas(String section) => sections.containsKey(section);

  List<CanvasSpot> spotsFor(String section) => sections[section] ?? const [];

  CanvasLayout copyWith({
    Map<String, List<CanvasSpot>>? sections,
    String? sha,
  }) => CanvasLayout(sections: sections ?? this.sections, sha: sha ?? this.sha);

  CanvasLayout withSection(String section, List<CanvasSpot> spots) =>
      copyWith(sections: {...sections, section: spots});

  CanvasLayout withoutSection(String section) => copyWith(
    sections: {
      for (final entry in sections.entries)
        if (entry.key != section) entry.key: entry.value,
    },
  );

  /// Follows a section being renamed, so its canvas does not stay behind
  /// pointing at a heading that has gone.
  CanvasLayout renameSection(String from, String to) {
    if (!sections.containsKey(from) || from == to) return this;
    return copyWith(
      sections: {
        for (final entry in sections.entries)
          if (entry.key == from) to: entry.value else entry.key: entry.value,
      },
    );
  }

  static String path(String slug) => 'canvas/$slug.json';

  String toJsonString() => const JsonEncoder.withIndent('  ').convert({
    'version': 1,
    'sections': {
      for (final entry in sections.entries)
        entry.key: [for (final spot in entry.value) spot.toJson()],
    },
  });

  /// Reads the file. A layout that cannot be understood is treated as absent
  /// rather than as an error: the canvas then opens as the list it is, which
  /// is the whole point of keeping the content somewhere else.
  static CanvasLayout parse(String source, {String? sha}) {
    try {
      final json = jsonDecode(source);
      if (json is! Map<String, dynamic>) return CanvasLayout(sha: sha);

      final raw = json['sections'];
      if (raw is! Map<String, dynamic>) return CanvasLayout(sha: sha);

      final sections = <String, List<CanvasSpot>>{};
      for (final entry in raw.entries) {
        final spots = entry.value;
        if (spots is! List) continue;
        sections[entry.key] = [
          for (final spot in spots)
            if (spot is Map<String, dynamic>) CanvasSpot.fromJson(spot),
        ];
      }
      return CanvasLayout(sections: sections, sha: sha);
    } on FormatException {
      return CanvasLayout(sha: sha);
    }
  }
}
