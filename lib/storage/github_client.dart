import 'dart:convert';

import 'package:http/http.dart' as http;

import 'remote_store.dart';

// The types the sync code shares with other stores used to live here, and a
// great deal still imports them from here.
export 'remote_store.dart'
    show RemoteEntry, RemoteFile, RemoteStore, StoreException;

/// Where the notes live: a repo, a branch, and a token that can write to it.
class GitHubConfig {
  const GitHubConfig({
    required this.owner,
    required this.repo,
    required this.branch,
    required this.token,
  });

  final String owner;
  final String repo;
  final String branch;
  final String token;

  bool get isComplete =>
      owner.isNotEmpty &&
      repo.isNotEmpty &&
      branch.isNotEmpty &&
      token.isNotEmpty;

  /// Where this points, said once, for telling two configs apart.
  String get locationKey => '$owner/$repo@$branch';
}

/// A request GitHub refused or could not answer.
///
/// A [StoreException] like any other store's, so the code that handles one
/// handles all of them; the name stays for the places that mean GitHub.
class GitHubException extends StoreException {
  GitHubException(super.statusCode, super.message);

  @override
  String toString() => 'GitHub $statusCode: $message';
}

/// Thin wrapper over the handful of GitHub REST endpoints the app needs.
class GitHubClient implements RemoteStore {
  GitHubClient(this.config, {http.Client? client})
    : _client = client ?? http.Client();

  static const _base = 'https://api.github.com';
  static const projectsDir = StoreLayout.projectsDir;

  /// Where completed items go when a list is tidied. Deliberately not under
  /// `projects/`, which is scanned: an archive is kept, not shown.
  static const archiveDir = StoreLayout.archiveDir;
  static const attachmentsDir = StoreLayout.attachmentsDir;

  final GitHubConfig config;
  final http.Client _client;

  Map<String, String> get _headers => {
    'Authorization': 'Bearer ${config.token}',
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
  };

  Uri _contentsUri(String path, {bool withRef = true}) {
    final encoded = path.split('/').map(Uri.encodeComponent).join('/');
    return Uri.parse(
      '$_base/repos/${config.owner}/${config.repo}/contents/$encoded',
    ).replace(queryParameters: withRef ? {'ref': config.branch} : null);
  }

  Future<http.Response> _getRepo() async {
    final response = await _client.get(
      Uri.parse('$_base/repos/${config.owner}/${config.repo}'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw GitHubException(response.statusCode, _errorMessage(response));
    }
    return response;
  }

  /// Verifies the token can reach the repo. Throws [GitHubException] if not.
  @override
  Future<void> checkAccess() => _getRepo();

  /// Whether the repo is private, which decides whether anything sensitive
  /// may be written into it.
  @override
  Future<bool> repoIsPrivate() async {
    final response = await _getRepo();
    final decoded = jsonDecode(response.body);
    // Absent or unreadable counts as public. Guessing wrong in this
    // direction costs a feature; guessing wrong the other way writes a key
    // somewhere the world can read it.
    return decoded is Map<String, dynamic> && decoded['private'] == true;
  }

  /// Lists a directory's files, with their SHAs, which a delete needs.
  /// An absent directory is not an error.
  @override
  Future<Map<String, String>> listDirectory(String path) async {
    final response = await _client.get(_contentsUri(path), headers: _headers);
    if (response.statusCode == 404) return const {};
    if (response.statusCode != 200) {
      throw GitHubException(response.statusCode, _errorMessage(response));
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! List) return const {};

    return {
      for (final entry in decoded.whereType<Map<String, dynamic>>())
        if (entry['type'] == 'file')
          entry['path'] as String: entry['sha'] as String,
    };
  }

  /// Lists the markdown files in `projects/` with the SHA each one currently
  /// has, which is what makes a poll cheap: one request says which files have
  /// moved on, so only those have to be fetched. Reading every file on every
  /// sync is what made checking often too expensive to do.
  @override
  Future<List<RemoteEntry>> listProjects() async {
    final response = await _client.get(
      _contentsUri(projectsDir),
      headers: _headers,
    );
    if (response.statusCode == 404) return const [];
    if (response.statusCode != 200) {
      throw GitHubException(response.statusCode, _errorMessage(response));
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! List) return const [];

    return decoded
        .whereType<Map<String, dynamic>>()
        .where((entry) => entry['type'] == 'file')
        .where((entry) => (entry['path'] as String?)?.endsWith('.md') ?? false)
        .map(
          (entry) => RemoteEntry(
            path: entry['path'] as String,
            sha: entry['sha'] as String? ?? '',
          ),
        )
        .toList();
  }

  @override
  Future<RemoteFile?> readFile(String path) async {
    final response = await _client.get(_contentsUri(path), headers: _headers);
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw GitHubException(response.statusCode, _errorMessage(response));
    }

    // Anything that is not a file's own JSON counts as not being there. A
    // path that happens to be a directory answers with a list, and a cast
    // straight to a map threw a type error that no caller was expecting —
    // which wedged the sync it happened inside.
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return null;
    if (decoded['path'] is! String || decoded['sha'] is! String) return null;

    final raw = (decoded['content'] as String? ?? '').replaceAll('\n', '');
    return RemoteFile(
      path: decoded['path'] as String,
      sha: decoded['sha'] as String,
      content: utf8.decode(base64.decode(raw)),
    );
  }

  /// Creates or updates a file. [sha] must be the SHA we last read for an
  /// update; passing a stale one makes GitHub reject the write with 409, which
  /// is how we notice someone else edited the file.
  @override
  Future<String> writeFile({
    required String path,
    required String content,
    required String message,
    String? sha,
  }) => writeBytes(
    path: path,
    bytes: utf8.encode(content),
    message: message,
    sha: sha,
  );

  /// Reads a file's raw bytes. Used for note attachments, which are binary and
  /// live in a private repo, so they cannot simply be fetched by URL.
  @override
  Future<List<int>?> readBytes(String path) async {
    final response = await _client.get(
      _contentsUri(path),
      headers: {..._headers, 'Accept': 'application/vnd.github.raw'},
    );
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw GitHubException(response.statusCode, _errorMessage(response));
    }
    return response.bodyBytes;
  }

  /// Creates or updates a file from raw bytes — an attached image, or the
  /// UTF-8 text [writeFile] hands it. [sha] works as it does there.
  @override
  Future<String> writeBytes({
    required String path,
    required List<int> bytes,
    required String message,
    String? sha,
  }) async {
    final response = await _client.put(
      _contentsUri(path, withRef: false),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'message': message,
        'content': base64.encode(bytes),
        'branch': config.branch,
        if (sha != null) 'sha': sha,
      }),
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw GitHubException(response.statusCode, _errorMessage(response));
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return (json['content'] as Map<String, dynamic>)['sha'] as String;
  }

  @override
  Future<void> deleteFile({
    required String path,
    required String sha,
    required String message,
  }) async {
    final request = http.Request('DELETE', _contentsUri(path, withRef: false))
      ..headers.addAll({..._headers, 'Content-Type': 'application/json'})
      ..body = jsonEncode({
        'message': message,
        'sha': sha,
        'branch': config.branch,
      });

    final response = await http.Response.fromStream(
      await _client.send(request),
    );
    if (response.statusCode != 200) {
      throw GitHubException(response.statusCode, _errorMessage(response));
    }
  }

  @override
  void dispose() => _client.close();

  static String _errorMessage(http.Response response) {
    try {
      final json = jsonDecode(response.body);
      if (json is Map<String, dynamic> && json['message'] is String) {
        return json['message'] as String;
      }
    } catch (_) {
      // Fall through to the raw body.
    }
    return response.reasonPhrase ?? 'Request failed';
  }
}
