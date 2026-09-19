import 'dart:convert';

/// What a thing on a canvas is.
enum CanvasSpotKind {
  /// An ordinary card: a picture or a piece of writing, as tall as what is
  /// in it.
  card,

  /// A labelled rectangle drawn behind the cards, grouping them together —
  /// moving it takes everything standing on it along.
  frame,

  /// A coloured note, the way a sticky note is coloured. The same card; only
  /// what it is drawn on is different.
  sticky,

  /// Writing with nothing drawn behind it — a caption on the board rather
  /// than a card on it.
  text;

  static CanvasSpotKind byName(String? name) => values.firstWhere(
    (value) => value.name == name,
    orElse: () => CanvasSpotKind.card,
  );
}

/// What a card is drawn on.
///
/// A short list of names rather than a colour value, so that the layout file
/// stays readable, the colours follow the app's light and dark, and nobody
/// ends up with a note nobody can read on the shade they are using.
enum CanvasColour {
  none,
  yellow,
  pink,
  blue,
  green,
  orange,
  purple;

  String get label => switch (this) {
    CanvasColour.none => 'Plain',
    CanvasColour.yellow => 'Yellow',
    CanvasColour.pink => 'Pink',
    CanvasColour.blue => 'Blue',
    CanvasColour.green => 'Green',
    CanvasColour.orange => 'Orange',
    CanvasColour.purple => 'Purple',
  };

  static CanvasColour byName(String? name) => values.firstWhere(
    (value) => value.name == name,
    orElse: () => CanvasColour.none,
  );
}

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
    this.kind = CanvasSpotKind.card,
    this.height,
    this.colour = CanvasColour.none,
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

  /// A card or a frame.
  final CanvasSpotKind kind;

  /// How tall it is drawn, for the things that do not take their height from
  /// what is in them. Null for a card, whose height follows its picture or
  /// its text; set for a frame, which is a rectangle someone drew.
  final double? height;

  /// What it is drawn on. Named rather than stored as a number so the layout
  /// file stays something a person can read and edit, and so the colours
  /// follow the app's light and dark instead of being fixed.
  final CanvasColour colour;

  bool get isFrame => kind == CanvasSpotKind.frame;

  /// Whether the card is drawn on something, as opposed to sitting straight
  /// on the canvas.
  bool get hasPaper => kind != CanvasSpotKind.text;

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
    CanvasSpotKind? kind,
    double? height,
    CanvasColour? colour,
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
    kind: kind ?? this.kind,
    height: height ?? this.height,
    colour: colour ?? this.colour,
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
    if (kind != CanvasSpotKind.card) 'kind': kind.name,
    if (height != null) 'h': height,
    if (colour != CanvasColour.none) 'colour': colour.name,
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
    kind: CanvasSpotKind.byName(json['kind'] as String?),
    height: json.containsKey('h') ? _number(json['h']) : null,
    colour: CanvasColour.byName(json['colour'] as String?),
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
      other.locked == locked &&
      other.kind == kind &&
      other.height == height &&
      other.colour == colour;

  @override
  int get hashCode => Object.hash(
    x,
    y,
    width,
    z,
    ref,
    rotation,
    flipX,
    flipY,
    locked,
    kind,
    height,
    colour,
  );
}

/// How one canvas is drawn, as opposed to what is on it.
///
/// Lives beside the positions for the same reason they do: none of it is
/// readable markdown, and none of it is content — losing it costs a
/// preference and nothing else.
class CanvasSettings {
  const CanvasSettings({
    this.height = defaultHeight,
    this.background = CanvasBackground.dots,
    this.dark,
  });

  /// How tall the canvas is drawn inside a project, in logical pixels. A
  /// canvas sits in a scrolling list, so it has to be given a height; this is
  /// the one the bottom edge drags.
  final double height;

  /// What is drawn under the cards.
  final CanvasBackground background;

  /// Null follows the app's theme, which is what a canvas did before this
  /// existed. Set, the canvas keeps its own light or dark regardless — a
  /// moodboard is often worth looking at on the opposite one.
  final bool? dark;

  static const defaultHeight = 420.0;
  static const minHeight = 160.0;
  static const maxHeight = 1600.0;

  static const standard = CanvasSettings();

  bool get isStandard =>
      height == defaultHeight &&
      background == CanvasBackground.dots &&
      dark == null;

  CanvasSettings copyWith({
    double? height,
    CanvasBackground? background,
    bool? dark,
    bool clearDark = false,
  }) => CanvasSettings(
    height: height ?? this.height,
    background: background ?? this.background,
    dark: clearDark ? null : (dark ?? this.dark),
  );

  Map<String, dynamic> toJson() => {
    if (height != defaultHeight) 'h': height,
    if (background != CanvasBackground.dots) 'bg': background.name,
    if (dark != null) 'dark': dark,
  };

  static CanvasSettings fromJson(Map<String, dynamic> json) => CanvasSettings(
    height: json.containsKey('h')
        ? CanvasSpot._number(json['h']).clamp(minHeight, maxHeight)
        : defaultHeight,
    background: CanvasBackground.byName(json['bg'] as String?),
    dark: json['dark'] is bool ? json['dark'] as bool : null,
  );

  @override
  bool operator ==(Object other) =>
      other is CanvasSettings &&
      other.height == height &&
      other.background == background &&
      other.dark == dark;

  @override
  int get hashCode => Object.hash(height, background, dark);
}

/// What is drawn under the cards on a canvas.
enum CanvasBackground {
  dots,
  grid,
  plain;

  String get label => switch (this) {
    CanvasBackground.dots => 'Dots',
    CanvasBackground.grid => 'Grid',
    CanvasBackground.plain => 'Plain',
  };

  static CanvasBackground byName(String? name) => values.firstWhere(
    (value) => value.name == name,
    orElse: () => CanvasBackground.dots,
  );
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
  const CanvasLayout({
    this.sections = const {},
    this.settings = const {},
    this.sha,
  });

  /// Section title to the spots of its cards, in the order the cards are in
  /// the file.
  final Map<String, List<CanvasSpot>> sections;

  /// Section title to how that canvas is drawn. A section missing from here
  /// is drawn the standard way, so a layout file written before this existed
  /// reads back unchanged.
  final Map<String, CanvasSettings> settings;

  /// The blob SHA GitHub last gave us for the layout file.
  final String? sha;

  static const empty = CanvasLayout();

  bool get isEmpty => sections.isEmpty;

  bool isCanvas(String section) => sections.containsKey(section);

  List<CanvasSpot> spotsFor(String section) => sections[section] ?? const [];

  CanvasSettings settingsFor(String section) =>
      settings[section] ?? CanvasSettings.standard;

  CanvasLayout copyWith({
    Map<String, List<CanvasSpot>>? sections,
    Map<String, CanvasSettings>? settings,
    String? sha,
  }) => CanvasLayout(
    sections: sections ?? this.sections,
    settings: settings ?? this.settings,
    sha: sha ?? this.sha,
  );

  /// Back to standard drops the entry rather than writing one that says
  /// nothing, so a canvas nobody has adjusted leaves no trace in the file.
  CanvasLayout withSettings(String section, CanvasSettings value) => copyWith(
    settings: {
      for (final entry in settings.entries)
        if (entry.key != section) entry.key: entry.value,
      if (!value.isStandard) section: value,
    },
  );

  CanvasLayout withSection(String section, List<CanvasSpot> spots) =>
      copyWith(sections: {...sections, section: spots});

  CanvasLayout withoutSection(String section) => copyWith(
    sections: {
      for (final entry in sections.entries)
        if (entry.key != section) entry.key: entry.value,
    },
    settings: {
      for (final entry in settings.entries)
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
      settings: {
        for (final entry in settings.entries)
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
    // Only when something was actually changed, so the file a canvas has
    // always written does not grow a key that says nothing.
    if (settings.values.any((value) => !value.isStandard))
      'settings': {
        for (final entry in settings.entries)
          if (!entry.value.isStandard) entry.key: entry.value.toJson(),
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
      final settings = <String, CanvasSettings>{};
      final rawSettings = json['settings'];
      if (rawSettings is Map<String, dynamic>) {
        for (final entry in rawSettings.entries) {
          final value = entry.value;
          if (value is Map<String, dynamic>) {
            settings[entry.key] = CanvasSettings.fromJson(value);
          }
        }
      }

      return CanvasLayout(sections: sections, settings: settings, sha: sha);
    } on FormatException {
      return CanvasLayout(sha: sha);
    }
  }
}

/// One point in a canvas's history: both of its files, together.
///
/// The arrangement alone would not be enough — a card deleted is gone from the
/// markdown, and putting its position back would put back a position with
/// nothing under it.
class CanvasStep {
  const CanvasStep({required this.body, required this.spots});

  final String body;
  final List<CanvasSpot> spots;

  @override
  bool operator ==(Object other) {
    if (other is! CanvasStep || other.body != body) return false;
    if (other.spots.length != spots.length) return false;
    for (var i = 0; i < spots.length; i++) {
      if (other.spots[i] != spots[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(body, Object.hashAll(spots));
}
