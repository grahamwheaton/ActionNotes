import 'dart:convert';

import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/storage/github_client.dart';
import 'package:actionnotes/storage/sync_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

const mine = GitHubConfig(
  owner: 'graham',
  repo: 'ProjectNotes',
  branch: 'main',
  token: 'mine-token',
);

const theirs = GitHubConfig(
  owner: 'graham',
  repo: 'SharedProjectNotes',
  branch: 'main',
  token: 'shared-token',
);

/// A GitHub that answers for every repo, keeping what is written to each one
/// apart — which is the whole point of having two.
class FakeGitHub {
  final Map<String, Map<String, String>> files = {};

  /// Repos that refuse everything, for a token that has been revoked.
  final Set<String> closed = {};

  Map<String, String> repo(String name) => files.putIfAbsent(name, () => {});

  http.Client clientFor(GitHubConfig config) {
    return MockClient((request) async {
      final name = config.repo;
      // What a revoked token actually gets. A 404 would be indistinguishable
      // from a repo that simply has no projects in it yet.
      if (closed.contains(name)) {
        return stubResponse(jsonEncode({'message': 'Bad credentials'}), 401);
      }

      // "Is this repo there?", which is what a share code is checked with
      // before it is kept.
      if (!request.url.path.contains('/contents/')) {
        return stubResponse(jsonEncode({'name': name}), 200);
      }

      final path = Uri.decodeFull(request.url.path).split('/contents/').last;

      if (request.method == 'PUT') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        repo(name)[path] = utf8.decode(
          base64.decode(body['content'] as String),
        );
        return stubResponse(
          jsonEncode({
            'content': {'sha': 'sha-$name-$path'},
          }),
          200,
        );
      }
      if (request.method == 'DELETE') {
        repo(name).remove(path);
        return stubResponse('{}', 200);
      }

      // A listing of projects/, or one file, or an empty folder.
      if (path == 'projects' || path.endsWith('/projects')) {
        return stubResponse(
          jsonEncode([
            for (final entry in repo(name).keys)
              if (entry.startsWith('projects/'))
                {'type': 'file', 'path': entry, 'sha': 'sha-$name-$entry'},
          ]),
          200,
        );
      }

      final content = repo(name)[path];
      if (content == null) return stubResponse('Not found', 404);
      return stubResponse(
        jsonEncode({
          'path': path,
          'sha': 'sha-$name-$path',
          'content': base64.encode(utf8.encode(content)),
          'encoding': 'base64',
        }),
        200,
      );
    });
  }
}

/// Lets whatever the app started in the background finish before the test
/// walks away from it — init kicks off a sync nobody awaits.
Future<void> settle(AppState state) async {
  for (var i = 0; i < 100 && state.syncing; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  await Future<void>.delayed(Duration.zero);
  state.dispose();
}

AppState stateWith(FakeGitHub github, FakeLocalStore store) {
  return AppState(
    localStore: store,
    settingsStore: FakeSettingsStore(config: mine),
    syncService: SyncService(
      localStore: store,
      clientFactory: (config) =>
          GitHubClient(config, client: github.clientFor(config)),
    ),
    pushDelay: const Duration(milliseconds: 10),
  );
}
