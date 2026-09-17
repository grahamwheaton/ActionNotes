import 'dart:convert';

import 'package:actionnotes/storage/github_account.dart';
import 'package:actionnotes/storage/github_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// One entry of a repos listing, with the fields the app reads.
Map<String, Object?> repoJson(String fullName, {String branch = 'main', bool private = true}) => {
      'full_name': fullName,
      'default_branch': branch,
      'private': private,
    };

void main() {
  test('reports who the token belongs to', () async {
    final account = GitHubAccount(
      'tok',
      client: MockClient((request) async {
        expect(request.url.path, '/user');
        expect(request.headers['Authorization'], 'Bearer tok');
        return http.Response(jsonEncode({'login': 'grahamwheaton'}), 200);
      }),
    );

    expect(await account.login(), 'grahamwheaton');
  });

  test('a rejected token is an error, not an empty name', () async {
    final account = GitHubAccount(
      'tok',
      client: MockClient(
        (_) async => http.Response(jsonEncode({'message': 'Bad credentials'}), 401),
      ),
    );

    await expectLater(
      account.login(),
      throwsA(isA<GitHubException>()
          .having((error) => error.statusCode, 'statusCode', 401)
          .having((error) => error.message, 'message', 'Bad credentials')),
    );
  });

  test('offers the repos the app is installed on, sorted by name', () async {
    final account = GitHubAccount(
      'tok',
      client: MockClient((request) async {
        final path = request.url.path;
        if (path == '/user/installations') {
          return http.Response(jsonEncode({'installations': [{'id': 42}]}), 200);
        }
        if (path == '/user/installations/42/repositories') {
          return http.Response(
            jsonEncode({
              'repositories': [
                repoJson('grahamwheaton/ProjectNotes', branch: 'master'),
                repoJson('grahamwheaton/ActionNotes', private: false),
              ],
            }),
            200,
          );
        }
        fail('unexpected request to $path');
      }),
    );

    final repos = await account.repos();

    expect(repos.map((repo) => repo.fullName),
        ['grahamwheaton/ActionNotes', 'grahamwheaton/ProjectNotes']);
    expect(repos.first.owner, 'grahamwheaton');
    expect(repos.first.name, 'ActionNotes');
    expect(repos.first.isPrivate, isFalse);
    expect(repos.last.defaultBranch, 'master');
  });

  test('walks every installation the token can see', () async {
    final account = GitHubAccount(
      'tok',
      client: MockClient((request) async {
        final path = request.url.path;
        if (path == '/user/installations') {
          return http.Response(
            jsonEncode({'installations': [{'id': 1}, {'id': 2}]}),
            200,
          );
        }
        if (path == '/user/installations/1/repositories') {
          return http.Response(
            jsonEncode({'repositories': [repoJson('graham/one')]}),
            200,
          );
        }
        if (path == '/user/installations/2/repositories') {
          return http.Response(
            jsonEncode({'repositories': [repoJson('acme/two')]}),
            200,
          );
        }
        fail('unexpected request to $path');
      }),
    );

    expect((await account.repos()).map((repo) => repo.fullName),
        ['acme/two', 'graham/one']);
  });

  // A personal access token cannot read installations at all. That is how the
  // fallback path is reached, and it must not read as a failure.
  test('falls back to the account\'s repos when installations are refused',
      () async {
    final seen = <String>[];
    final account = GitHubAccount(
      'tok',
      client: MockClient((request) async {
        seen.add(request.url.path);
        if (request.url.path == '/user/installations') {
          return http.Response(
            jsonEncode({'message': 'Resource not accessible by personal access token'}),
            403,
          );
        }
        return http.Response(jsonEncode([repoJson('graham/notes')]), 200);
      }),
    );

    expect((await account.repos()).single.fullName, 'graham/notes');
    expect(seen, ['/user/installations', '/user/repos']);
  });

  test('falls back when the app is installed nowhere', () async {
    final seen = <String>[];
    final account = GitHubAccount(
      'tok',
      client: MockClient((request) async {
        seen.add(request.url.path);
        if (request.url.path == '/user/installations') {
          return http.Response(jsonEncode({'installations': <Object>[]}), 200);
        }
        return http.Response(jsonEncode(<Object>[]), 200);
      }),
    );

    expect(await account.repos(), isEmpty);
    expect(seen, ['/user/installations', '/user/repos']);
  });

  test('keeps reading pages while they come back full', () async {
    final pages = <String?>[];
    final account = GitHubAccount(
      'tok',
      client: MockClient((request) async {
        if (request.url.path == '/user/installations') {
          return http.Response(jsonEncode({'message': 'no'}), 403);
        }
        final page = request.url.queryParameters['page'];
        pages.add(page);
        expect(request.url.queryParameters['per_page'], '100');
        final body = page == '1'
            ? [for (var i = 0; i < 100; i++) repoJson('graham/repo-$i')]
            : [repoJson('graham/last')];
        return http.Response(jsonEncode(body), 200);
      }),
    );

    final repos = await account.repos();

    expect(pages, ['1', '2']);
    expect(repos, hasLength(101));
    expect(repos.map((repo) => repo.fullName), contains('graham/last'));
  });

  test('a repo listed twice is offered once', () async {
    final account = GitHubAccount(
      'tok',
      client: MockClient((request) async {
        if (request.url.path == '/user/installations') {
          return http.Response(
            jsonEncode({'installations': [{'id': 1}, {'id': 2}]}),
            200,
          );
        }
        return http.Response(
          jsonEncode({'repositories': [repoJson('graham/notes')]}),
          200,
        );
      }),
    );

    expect(await account.repos(), hasLength(1));
  });

  test('skips entries without a usable name rather than failing', () async {
    final account = GitHubAccount(
      'tok',
      client: MockClient((request) async {
        if (request.url.path == '/user/installations') {
          return http.Response(jsonEncode({'message': 'no'}), 403);
        }
        return http.Response(
          jsonEncode([
            {'name': 'notes'},
            {'full_name': 'nameless'},
            repoJson('graham/notes'),
          ]),
          200,
        );
      }),
    );

    expect((await account.repos()).single.fullName, 'graham/notes');
  });

  test('a repo with no commits yet is offered against main', () {
    expect(RepoRef.fromJson({'full_name': 'graham/fresh'})!.defaultBranch, 'main');
  });

  test('a listing that is not JSON is an error, not a crash', () async {
    final account = GitHubAccount(
      'tok',
      client: MockClient((_) async => http.Response('<html>down</html>', 200)),
    );

    await expectLater(account.repos(), throwsA(isA<GitHubException>()));
  });
}
