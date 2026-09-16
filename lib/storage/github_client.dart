import 'dart:convert';

import 'package:http/http.dart' as http;

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
      owner.isNotEmpty && repo.isNotEmpty && branch.isNotEmpty && token.isNotEmpty;
}

/// A file as GitHub reports it.
class RemoteFile {
  const RemoteFile({required this.path, required this.sha, required this.content});

  final String path;
  final String sha;
  final String content;
}

class GitHubException implements Exception {
  GitHubException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  /// True when retrying will not help — bad token, missing repo, and so on.
  bool get isFatal => statusCode == 401 || statusCode == 403 || statusCode == 404;

  @override
  String toString() => 'GitHub $statusCode: $message';
}

/// Thin wrapper over the handful of GitHub REST endpoints the app needs.
class GitHubClient {
  GitHubClient(this.config, {http.Client? client})
      : _client = client ?? http.Client();

  static const _base = 'https://api.github.com';
  static const projectsDir = 'projects';
  static const attachmentsDir = 'attachments';

  final GitHubConfig config;
  final http.Client _client;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${config.token}',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  Uri _contentsUri(String path, {bool withRef = true}) {
    final encoded = path.split('/').map(Uri.encodeComponent).join('/');
    return Uri.parse('$_base/repos/${config.owner}/${config.repo}/contents/$encoded')
        .replace(queryParameters: withRef ? {'ref': config.branch} : null);
  }

  /// Verifies the token can reach the repo. Throws [GitHubException] if not.
  Future<void> checkAccess() async {
    final response = await _client.get(
      Uri.parse('$_base/repos/${config.owner}/${config.repo}'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw GitHubException(response.statusCode, _errorMessage(response));
    }
  }

  /// Lists a directory's files, with their SHAs, which a delete needs.
  /// An absent directory is not an error.
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

  /// Lists the markdown files in `projects/`. An absent directory is not an
  /// error — it just means nothing has been saved yet.
  Future<List<String>> listProjectPaths() async {
    final response = await _client.get(_contentsUri(projectsDir), headers: _headers);
    if (response.statusCode == 404) return const [];
    if (response.statusCode != 200) {
      throw GitHubException(response.statusCode, _errorMessage(response));
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! List) return const [];

    return decoded
        .whereType<Map<String, dynamic>>()
        .where((entry) => entry['type'] == 'file')
        .map((entry) => entry['path'] as String)
        .where((path) => path.endsWith('.md'))
        .toList();
  }

  Future<RemoteFile?> readFile(String path) async {
    final response = await _client.get(_contentsUri(path), headers: _headers);
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw GitHubException(response.statusCode, _errorMessage(response));
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final raw = (json['content'] as String? ?? '').replaceAll('\n', '');
    return RemoteFile(
      path: json['path'] as String,
      sha: json['sha'] as String,
      content: utf8.decode(base64.decode(raw)),
    );
  }

  /// Creates or updates a file. [sha] must be the SHA we last read for an
  /// update; passing a stale one makes GitHub reject the write with 409, which
  /// is how we notice someone else edited the file.
  Future<String> writeFile({
    required String path,
    required String content,
    required String message,
    String? sha,
  }) async {
    final response = await _client.put(
      _contentsUri(path, withRef: false),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'message': message,
        'content': base64.encode(utf8.encode(content)),
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

  /// Reads a file's raw bytes. Used for note attachments, which are binary and
  /// live in a private repo, so they cannot simply be fetched by URL.
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

  /// Uploads raw bytes, for an image being attached to an item's notes.
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

    final response = await http.Response.fromStream(await _client.send(request));
    if (response.statusCode != 200) {
      throw GitHubException(response.statusCode, _errorMessage(response));
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
      // Fall through to the raw body.
    }
    return response.reasonPhrase ?? 'Request failed';
  }
}
