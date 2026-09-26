import 'dart:convert';

import 'package:actionnotes/storage/github_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const config = GitHubConfig(
  owner: 'graham',
  repo: 'notes',
  branch: 'main',
  token: 'tok',
);

String encodeContent(String text) => base64.encode(utf8.encode(text));

void main() {
  test('sends the token and API version on every request', () async {
    late http.Request seen;
    final client = GitHubClient(
      config,
      client: MockClient((request) async {
        seen = request;
        return http.Response('{}', 200);
      }),
    );

    await client.checkAccess();

    expect(seen.headers['Authorization'], 'Bearer tok');
    expect(seen.headers['X-GitHub-Api-Version'], '2022-11-28');
  });

  test('a missing projects/ directory is empty, not an error', () async {
    final client = GitHubClient(
      config,
      client: MockClient((_) async => http.Response('Not Found', 404)),
    );

    expect(await client.listProjects(), isEmpty);
  });

  test('lists only markdown files, ignoring directories', () async {
    final client = GitHubClient(
      config,
      client: MockClient((_) async => http.Response(
            jsonEncode([
              {'type': 'file', 'path': 'projects/a.md'},
              {'type': 'file', 'path': 'projects/notes.txt'},
              {'type': 'dir', 'path': 'projects/archive'},
            ]),
            200,
          )),
    );

    expect(
      (await client.listProjects()).map((entry) => entry.path),
      ['projects/a.md'],
    );
  });

  test('decodes base64 content, including the newlines GitHub inserts',
      () async {
    final wrapped = '${encodeContent('# Hi\n\n- [ ] Item\n')}\n';
    final client = GitHubClient(
      config,
      client: MockClient((_) async => http.Response(
            jsonEncode({
              'path': 'projects/a.md',
              'sha': 'abc',
              'content': wrapped,
            }),
            200,
          )),
    );

    final file = await client.readFile('projects/a.md');

    expect(file!.sha, 'abc');
    expect(file.content, '# Hi\n\n- [ ] Item\n');
  });

  test('a write sends the branch and the SHA it was given', () async {
    late Map<String, dynamic> body;
    final client = GitHubClient(
      config,
      client: MockClient((request) async {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'content': {'sha': 'new-sha'},
          }),
          200,
        );
      }),
    );

    final sha = await client.writeFile(
      path: 'projects/a.md',
      content: 'hello',
      message: 'Update A',
      sha: 'old-sha',
    );

    expect(sha, 'new-sha');
    expect(body['branch'], 'main');
    expect(body['sha'], 'old-sha');
    expect(utf8.decode(base64.decode(body['content'] as String)), 'hello');
  });

  test('a first write omits the SHA so GitHub creates the file', () async {
    late Map<String, dynamic> body;
    final client = GitHubClient(
      config,
      client: MockClient((request) async {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'content': {'sha': 'created'},
          }),
          201,
        );
      }),
    );

    await client.writeFile(
      path: 'projects/new.md',
      content: 'hi',
      message: 'Create',
    );

    expect(body.containsKey('sha'), isFalse);
  });

  test('surfaces GitHub error messages', () async {
    final client = GitHubClient(
      config,
      client: MockClient((_) async => http.Response(
            jsonEncode({'message': 'Bad credentials'}),
            401,
          )),
    );

    await expectLater(
      client.checkAccess(),
      throwsA(
        isA<GitHubException>()
            .having((e) => e.message, 'message', 'Bad credentials')
            .having((e) => e.isFatal, 'isFatal', isTrue),
      ),
    );
  });

  test('a conflicting write is not fatal, so sync can retry it', () async {
    final client = GitHubClient(
      config,
      client: MockClient((_) async => http.Response('{"message":"conflict"}', 409)),
    );

    await expectLater(
      client.writeFile(
        path: 'projects/a.md',
        content: 'x',
        message: 'm',
        sha: 'stale',
      ),
      throwsA(isA<GitHubException>()
          .having((e) => e.statusCode, 'statusCode', 409)
          .having((e) => e.isFatal, 'isFatal', isFalse)),
    );
  });
}
