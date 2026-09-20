import 'dart:convert';

/// How the project list is arranged: what order things come in, and which
/// group each project sits in.
///
/// Kept apart from the projects themselves. A project is a markdown file that
/// anybody can read, and where it sits in one person's sidebar is not part of
/// what it says — the same way a canvas card's position lives beside the card
/// rather than in it. It also means rearranging the list is one small file
/// changing, not every project rewritten.
///
/// Projects are referred to by key, which for a shared one carries its
/// notebook — so your own arrangement can put a shared list wherever you like
/// without saying anything to the people you share it with.
class SidebarLayout {
  const SidebarLayout({
    this.groups = const [],
    this.loose = const [],
    this.sha,
  });

  /// The groups, in the order they appear.
  final List<ProjectGroup> groups;

  /// Projects in no group, in the order they appear. They come first, above
  /// the groups: a list you have not filed is one you are still using.
  final List<String> loose;

  final String? sha;

  static const path = '.actionnotes/sidebar.json';
  static const empty = SidebarLayout();

  bool get isEmpty => groups.isEmpty && loose.isEmpty;

  /// Every project this layout mentions, so one it has never heard of can be
  /// told from one deliberately placed.
  Set<String> get known => {
    ...loose,
    for (final group in groups) ...group.slugs,
  };

  /// The group a project is in, or null when it is loose.
  ProjectGroup? groupOf(String slug) {
    for (final group in groups) {
      if (group.slugs.contains(slug)) return group;
    }
    return null;
  }

  /// The layout with every trace of [slug] removed, which is what both
  /// deleting a project and moving it somewhere else start with.
  SidebarLayout without(String slug) => SidebarLayout(
    groups: [
      for (final group in groups)
        group.copyWith(slugs: group.slugs.where((s) => s != slug).toList()),
    ],
    loose: loose.where((s) => s != slug).toList(),
    sha: sha,
  );

  /// Puts [slug] into [group] — or, with a null group, back among the loose
  /// ones — at [at], or at the end when that is null.
  SidebarLayout place(String slug, {String? group, int? at}) {
    final cleared = without(slug);

    if (group == null) {
      final next = [...cleared.loose];
      next.insert(at?.clamp(0, next.length) ?? next.length, slug);
      return SidebarLayout(groups: cleared.groups, loose: next, sha: sha);
    }

    return SidebarLayout(
      groups: [
        for (final one in cleared.groups)
          if (one.name == group)
            one.copyWith(
              slugs: [...one.slugs]
                ..insert(at?.clamp(0, one.slugs.length) ?? one.slugs.length, slug),
            )
          else
            one,
      ],
      loose: cleared.loose,
      sha: sha,
    );
  }

  SidebarLayout withGroup(ProjectGroup group) =>
      SidebarLayout(groups: [...groups, group], loose: loose, sha: sha);

  /// Takes a group away, leaving what was in it loose rather than deleting
  /// anybody's projects — a group is a way of looking at a list, and putting
  /// one away should never lose what it held.
  SidebarLayout withoutGroup(String name) {
    final going = groups.where((group) => group.name == name);
    return SidebarLayout(
      groups: groups.where((group) => group.name != name).toList(),
      loose: [...loose, for (final group in going) ...group.slugs],
      sha: sha,
    );
  }

  SidebarLayout withGroupAt(String name, int at) {
    final moving = groups.where((group) => group.name == name).toList();
    if (moving.isEmpty) return this;

    final rest = groups.where((group) => group.name != name).toList()
      ..insert(at.clamp(0, groups.length - 1), moving.single);
    return SidebarLayout(groups: rest, loose: loose, sha: sha);
  }

  SidebarLayout renameGroup(String from, String to) => SidebarLayout(
    groups: [
      for (final group in groups)
        group.name == from ? group.copyWith(name: to) : group,
    ],
    loose: loose,
    sha: sha,
  );

  SidebarLayout withGroupChanged(
    String name, {
    String? colour,
    bool? collapsed,
  }) => SidebarLayout(
    groups: [
      for (final group in groups)
        if (group.name == name)
          group.copyWith(colour: colour, collapsed: collapsed)
        else
          group,
    ],
    loose: loose,
    sha: sha,
  );

  /// Drops anything that no longer exists, so a project deleted elsewhere
  /// does not sit in the file for ever.
  SidebarLayout prunedTo(Set<String> slugs) => SidebarLayout(
    groups: [
      for (final group in groups)
        group.copyWith(slugs: group.slugs.where(slugs.contains).toList()),
    ],
    loose: loose.where(slugs.contains).toList(),
    sha: sha,
  );

  SidebarLayout copyWith({String? sha}) =>
      SidebarLayout(groups: groups, loose: loose, sha: sha ?? this.sha);

  static SidebarLayout parse(String content, {String? sha}) {
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) {
        return SidebarLayout(sha: sha);
      }

      return SidebarLayout(
        groups: [
          for (final entry
              in (decoded['groups'] as List? ?? const [])
                  .whereType<Map<String, dynamic>>())
            if (ProjectGroup.fromJson(entry) case final group?) group,
        ],
        loose: [
          for (final slug in decoded['loose'] as List? ?? const [])
            if (slug is String && slug.isNotEmpty) slug,
        ],
        sha: sha,
      );
    } catch (_) {
      // A file somebody has edited into something unreadable should not stop
      // the sidebar drawing. No arrangement is what it was before there was
      // one: everything loose, in the order it comes.
      return SidebarLayout(sha: sha);
    }
  }

  String serialize() {
    const encoder = JsonEncoder.withIndent('  ');
    return '${encoder.convert({
      'version': 1,
      'groups': [for (final group in groups) group.toJson()],
      'loose': loose,
    })}\n';
  }

  bool sameAs(SidebarLayout other) => serialize() == other.serialize();
}

class ProjectGroup {
  const ProjectGroup({
    required this.name,
    this.colour = '',
    this.collapsed = false,
    this.slugs = const [],
  });

  final String name;

  /// One of the named colours the app knows, or empty for the ordinary one.
  /// A name rather than a hex value, so a group keeps its colour when the
  /// theme changes and reads as something in the file.
  final String colour;

  final bool collapsed;
  final List<String> slugs;

  ProjectGroup copyWith({
    String? name,
    String? colour,
    bool? collapsed,
    List<String>? slugs,
  }) => ProjectGroup(
    name: name ?? this.name,
    colour: colour ?? this.colour,
    collapsed: collapsed ?? this.collapsed,
    slugs: slugs ?? this.slugs,
  );

  static ProjectGroup? fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String || name.trim().isEmpty) return null;

    return ProjectGroup(
      name: name.trim(),
      colour: (json['colour'] as String?)?.trim() ?? '',
      collapsed: json['collapsed'] == true,
      slugs: [
        for (final slug in json['projects'] as List? ?? const [])
          if (slug is String && slug.isNotEmpty) slug,
      ],
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    if (colour.isNotEmpty) 'colour': colour,
    if (collapsed) 'collapsed': true,
    'projects': slugs,
  };
}
