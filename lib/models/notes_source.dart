import '../storage/github_client.dart';

/// Where a project comes from: your own repo, or one someone shared with you.
///
/// The app used to have exactly one repo, and every project in it was yours.
/// Sharing means a project can now live somewhere else, and the thing that
/// tells them apart has to be carried everywhere a project is — which repo to
/// write to, which folder on the device holds the copy, and what the sidebar
/// says beside it.
enum SourceKind {
  /// The repo you signed in to. There is exactly one.
  mine,

  /// A repo someone handed you a share code for.
  shared,
}

class NotesSource {
  const NotesSource({
    required this.id,
    required this.kind,
    required this.config,
    this.label = '',
  });

  /// Stable, and used as the folder name for this source's local copy — so it
  /// is built from the repo rather than from anything a person can retype.
  final String id;

  final SourceKind kind;
  final GitHubConfig config;

  /// What to call it on screen. Empty falls back to the repo's own name,
  /// which is what someone who has just pasted a code will recognise.
  final String label;

  static const mineId = 'mine';

  /// The id a shared repo gets, so pasting the same code twice adds it once.
  static String idFor(GitHubConfig config) {
    final name = '${config.owner}-${config.repo}'
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return 'shared-${name.isEmpty ? 'repo' : name}';
  }

  static NotesSource ownedBy(GitHubConfig config) =>
      NotesSource(id: mineId, kind: SourceKind.mine, config: config);

  static NotesSource sharedFrom(GitHubConfig config, {String label = ''}) =>
      NotesSource(
        id: idFor(config),
        kind: SourceKind.shared,
        config: config,
        label: label,
      );

  bool get isMine => kind == SourceKind.mine;

  /// What the sidebar and settings call it.
  String get name {
    if (label.trim().isNotEmpty) return label.trim();
    if (isMine) return 'My notes';
    return config.repo.isEmpty ? 'Shared' : config.repo;
  }

  /// Where it actually is, said out loud: what a person needs to check when
  /// two shared notebooks are called similar things.
  String get where => '${config.owner}/${config.repo}';

  NotesSource copyWith({GitHubConfig? config, String? label}) => NotesSource(
    id: id,
    kind: kind,
    config: config ?? this.config,
    label: label ?? this.label,
  );

  /// The token is deliberately not here: this is what goes into ordinary
  /// preferences, and a token belongs in the keystore beside it.
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'owner': config.owner,
    'repo': config.repo,
    'branch': config.branch,
    if (label.trim().isNotEmpty) 'label': label.trim(),
  };

  /// Reads one back, with the token supplied from wherever tokens are kept.
  static NotesSource? fromJson(Map<String, dynamic> json, String token) {
    final id = json['id'];
    final owner = json['owner'];
    final repo = json['repo'];
    if (id is! String || id.isEmpty) return null;
    if (owner is! String || repo is! String) return null;

    return NotesSource(
      id: id,
      kind: json['kind'] == SourceKind.shared.name
          ? SourceKind.shared
          : SourceKind.mine,
      label: json['label'] as String? ?? '',
      config: GitHubConfig(
        owner: owner,
        repo: repo,
        branch: (json['branch'] as String?)?.trim().isNotEmpty == true
            ? json['branch'] as String
            : 'main',
        token: token,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NotesSource &&
      other.id == id &&
      other.kind == kind &&
      other.label == label &&
      other.config.owner == config.owner &&
      other.config.repo == config.repo &&
      other.config.branch == config.branch &&
      other.config.token == config.token;

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    label,
    config.owner,
    config.repo,
    config.branch,
    config.token,
  );

  @override
  String toString() => 'NotesSource($id, $where)';
}
