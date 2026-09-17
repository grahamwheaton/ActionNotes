import 'dart:convert';

import 'package:http/http.dart' as http;

import 'github_client.dart';

/// A repo a token can reach, as much of it as filling in the settings needs.
class RepoRef {
  const RepoRef({
    required this.owner,
    required this.name,
    required this.defaultBranch,
    this.isPrivate = false,
  });

  /// Reads one entry of a repos listing. Returns null for anything that does
  /// not carry a full name, which is the one field everything else is derived
  /// from.
  static RepoRef? fromJson(Map<String, dynamic> json) {
    final fullName = json['full_name'];
    if (fullName is! String || !fullName.contains('/')) return null;

    final slash = fullName.indexOf('/');
    return RepoRef(
      owner: fullName.substring(0, slash),
      name: fullName.substring(slash + 1),
      // A brand new repo has no commits and so no default branch; `main` is
      // what GitHub will call the first one, and what the app writes to.
      defaultBranch: json['default_branch'] as String? ?? 'main',
      isPrivate: json['private'] as bool? ?? false,
    );
  }

  final String owner;
  final String name;
  final String defaultBranch;
  final bool isPrivate;

  String get fullName => '$owner/$name';
}

/// What a token is, rather than what it can do to one repo: who it belongs to
/// and which repos it reaches.
///
/// This is deliberately separate from [GitHubClient], which is built around an
/// owner and repo that are already known. These are the calls made precisely
/// because they are not known yet.
class GitHubAccount {
  GitHubAccount(this.token, {http.Client? client})
      : _client = client ?? http.Client();

  static const _base = 'https://api.github.com';

  /// How many pages to walk before giving up. Someone with more than a
  /// thousand repos is better served by typing the name.
  static const _maxPages = 10;

  final String token;
  final http.Client _client;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  /// The account the token belongs to — the owner to fill in, unless the notes
  /// live under an org.
  Future<String> login() async {
    final json = await _getJson('/user');
    final login = json is Map<String, dynamic> ? json['login'] : null;
    if (login is! String || login.isEmpty) {
      throw GitHubException(200, 'GitHub did not say who this token belongs to.');
    }
    return login;
  }

  /// The repos this token can reach, sorted by name.
  ///
  /// For a signed-in user token that means the repos the ActionNotes app is
  /// installed on — which is exactly the set that will work, so anything
  /// offered here can be saved with some confidence. A personal access token
  /// cannot see installations at all, so it falls back to the repos the
  /// account has access to, which is a longer list including ones the token
  /// itself may not be scoped to.
  Future<List<RepoRef>> repos() async {
    final fromInstallations = await _installationRepos();
    final found = fromInstallations ?? await _paged('/user/repos', (json) => json);

    final byName = <String, RepoRef>{};
    for (final entry in found) {
      final repo = RepoRef.fromJson(entry);
      if (repo != null) byName[repo.fullName.toLowerCase()] = repo;
    }

    final repos = byName.values.toList()
      ..sort((a, b) => a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase()));
    return repos;
  }

  /// The repos reachable through the app's installations, or null if this
  /// token cannot see installations — which is how a personal access token
  /// answers, and is not an error.
  Future<List<Map<String, dynamic>>?> _installationRepos() async {
    final List<Map<String, dynamic>> installations;
    try {
      installations = await _paged(
        '/user/installations',
        (json) => json is Map<String, dynamic> ? json['installations'] : null,
      );
    } on GitHubException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403 || error.statusCode == 404) {
        return null;
      }
      rethrow;
    }

    if (installations.isEmpty) return null;

    final repos = <Map<String, dynamic>>[];
    for (final installation in installations) {
      final id = installation['id'];
      if (id == null) continue;
      repos.addAll(await _paged(
        '/user/installations/$id/repositories',
        (json) => json is Map<String, dynamic> ? json['repositories'] : null,
      ));
    }
    return repos;
  }

  /// Walks a paged listing. [extract] pulls the list out of one page's body,
  /// because GitHub returns a bare array from some endpoints and a wrapped one
  /// from others.
  Future<List<Map<String, dynamic>>> _paged(
    String path,
    Object? Function(Object? json) extract,
  ) async {
    const perPage = 100;
    final all = <Map<String, dynamic>>[];

    for (var page = 1; page <= _maxPages; page++) {
      final json = await _getJson(path, {
        'per_page': '$perPage',
        'page': '$page',
      });
      final list = extract(json);
      if (list is! List) break;

      all.addAll(list.whereType<Map<String, dynamic>>());
      if (list.length < perPage) break;
    }

    return all;
  }

  Future<Object?> _getJson(String path, [Map<String, String>? query]) async {
    final uri = Uri.parse('$_base$path')
        .replace(queryParameters: query?.isEmpty ?? true ? null : query);
    final response = await _client.get(uri, headers: _headers);

    if (response.statusCode != 200) {
      throw GitHubException(response.statusCode, _errorMessage(response));
    }

    try {
      return jsonDecode(response.body);
    } catch (_) {
      throw GitHubException(response.statusCode, 'GitHub sent something unreadable.');
    }
  }

  void dispose() => _client.close();

  static String _errorMessage(http.Response response) {
    try {
      final json = jsonDecode(response.body);
      if (json is Map<String, dynamic> && json['message'] is String) {
        return json['message'] as String;
      }
    } catch (_) {
      // Fall through to the status line.
    }
    return response.reasonPhrase ?? 'Request failed';
  }
}
