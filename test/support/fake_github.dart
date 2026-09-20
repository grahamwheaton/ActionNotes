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

  /// Files actually fetched, so a test can show that a sync did not download
  /// a list that had not changed.
  final List<String> reads = [];

  /// Repos anybody can read, which is what decides whether a share code —
  /// which carries a token — may be written into one.
  final Set<String> public = {};

  Map<String, String> repo(String name) => files.putIfAbsent(name, () => {});

  /// A SHA that follows the content, the way a real one does — so a file that
  /// has not been written keeps its SHA and a listing can be trusted.
  String shaOf(String name, String path) =>
      'sha-$name-$path-${(repo(name)[path] ?? '').hashCode}';

  http.Client clientFor(GitHubConfig config) {
    return MockClient((request) async {
      final name = config.repo;
      // What a revoked token actually gets. A 404 would be indistinguishable
      // from a repo that simply has no projects in it yet.
      if (closed.contains(name)) {
        return stubResponse(jsonEncode({'message': 'Bad credentials'}), 401);
      }

      // "Is this repo there?", which is what a share code is checked with
      // before it is kept — and what says whether anything sensitive may be
      // written into it.
      if (!request.url.path.contains('/contents/')) {
        return stubResponse(
          jsonEncode({'name': name, 'private': !public.contains(name)}),
          200,
        );
      }

      final path = Uri.decodeFull(request.url.path).split('/contents/').last;

      if (request.method == 'PUT') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;

        // GitHub accepts a write only against the SHA the file has now, and
        // refuses anything else with a 409. Without that here, a test of two
        // people writing at once would quietly let one overwrite the other
        // and call it a pass.
        final sent = body['sha'] as String?;
        final current = repo(name).containsKey(path) ? shaOf(name, path) : null;
        if (sent != current) {
          return stubResponse(jsonEncode({'message': 'does not match'}), 409);
        }

        repo(name)[path] = utf8.decode(
          base64.decode(body['content'] as String),
        );
        return stubResponse(
          jsonEncode({
            'content': {'sha': shaOf(name, path)},
          }),
          200,
        );
      }
      if (request.method == 'DELETE') {
        repo(name).remove(path);
        return stubResponse('{}', 200);
      }

      // A folder listing: projects/, canvas/, attachments/<project>/. A
      // path with no dot in its last part is a folder, the way GitHub
      // answers a directory with a list rather than a file.
      if (!path.split('/').last.contains('.')) {
        return stubResponse(
          jsonEncode([
            for (final entry in repo(name).keys)
              if (entry.startsWith('$path/'))
                {'type': 'file', 'path': entry, 'sha': shaOf(name, entry)},
          ]),
          200,
        );
      }

      final content = repo(name)[path];
      if (content == null) return stubResponse('Not found', 404);
      reads.add(path);
      return stubResponse(
        jsonEncode({
          'path': path,
          'sha': shaOf(name, path),
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

/// Somebody who has never signed in to GitHub and never will: the only
/// notebook they have is the shared one whose code they pasted.
///
/// This is the common case for everyone after the first person, so almost
/// nothing should depend on their own repo being set up.
AppState guestWith(
  FakeGitHub github,
  FakeLocalStore store, {
  FakeAttachmentStore? attachments,
}) {
  return AppState(
    localStore: store,
    settingsStore: FakeSettingsStore(),
    syncService: SyncService(
      localStore: store,
      clientFactory: (config) =>
          GitHubClient(config, client: github.clientFor(config)),
    ),
    attachmentStore: attachments,
    pushDelay: const Duration(milliseconds: 10),
  );
}
