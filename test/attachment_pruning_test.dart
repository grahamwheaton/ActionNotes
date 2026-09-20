import 'dart:convert';

import 'package:actionnotes/markdown/project_links.dart';
import 'package:actionnotes/models/checklist_item.dart';
import 'package:actionnotes/models/project.dart';
import 'package:actionnotes/storage/github_client.dart';
import 'package:actionnotes/storage/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fakes.dart';

/// Records which paths a delete was issued for.
http.Client trackingClient({
  required Map<String, String> directory,
  required List<String> deleted,
}) {
  return MockClient((request) async {
    if (request.method == 'DELETE') {
      deleted.add(Uri.decodeFull(request.url.path).split('/contents/').last);
      return stubResponse('{}', 200);
    }
    // Only what is actually in the folder being asked for. GitHub scopes a
    // listing to its path, and a fake that hands back everything would let a
    // sweep of one folder appear to reach into another.
    final at = Uri.decodeFull(request.url.path).split('/contents/').last;
    final inside = {
      for (final entry in directory.entries)
        if (entry.key.startsWith('$at/')) entry.key: entry.value,
    };

    return stubResponse(
      jsonEncode([
        for (final entry in inside.entries)
          {'type': 'file', 'path': entry.key, 'sha': entry.value},
      ]),
      200,
    );
  });
}

void main() {
  group('attachmentNames', () {
    test('finds the files a note refers to', () {
      const notes = '''
![one](../attachments/trip/one.png)
and ![two](../attachments/trip/two.jpg)
''';

      expect(ProjectLinks.attachmentNames(notes), {'one.png', 'two.jpg'});
    });

    test('ignores project links and external images', () {
      const notes = '''
[House move](house-move.md)
![remote](https://example.com/a.png)
''';

      expect(ProjectLinks.attachmentNames(notes), isEmpty);
    });
  });

  group('pruneAttachments', () {
    Project projectWith(List<String> referenced) {
      return Project(
        slug: 'trip',
        title: 'Trip',
        items: [
          for (final name in referenced)
            ChecklistItem(
              text: 'item',
              notes: '![$name](../attachments/trip/$name)',
            ),
        ],
      );
    }

    test('removes a file nothing points at any more', () async {
      final deleted = <String>[];
      final sync = SyncService(
        localStore: FakeLocalStore(),
        clientFactory: (config) => GitHubClient(
          config,
          client: trackingClient(
            directory: {
              'attachments/trip/kept.png': 'sha-kept',
              'attachments/trip/orphan.png': 'sha-orphan',
            },
            deleted: deleted,
          ),
        ),
      );

      await sync.pruneAttachments(testConfig, projectWith(['kept.png']));

      expect(deleted, ['attachments/trip/orphan.png']);
    });

    test('leaves every referenced file alone', () async {
      final deleted = <String>[];
      final sync = SyncService(
        localStore: FakeLocalStore(),
        clientFactory: (config) => GitHubClient(
          config,
          client: trackingClient(
            directory: {
              'attachments/trip/a.png': 'sha-a',
              'attachments/trip/b.png': 'sha-b',
            },
            deleted: deleted,
          ),
        ),
      );

      await sync.pruneAttachments(testConfig, projectWith(['a.png', 'b.png']));

      expect(deleted, isEmpty);
    });

    test('counts an image in the project notes as referenced', () async {
      final deleted = <String>[];
      final sync = SyncService(
        localStore: FakeLocalStore(),
        clientFactory: (config) => GitHubClient(
          config,
          client: trackingClient(
            directory: {'attachments/trip/in-notes.png': 'sha'},
            deleted: deleted,
          ),
        ),
      );

      await sync.pruneAttachments(
        testConfig,
        Project(
          slug: 'trip',
          title: 'Trip',
          notes: '![x](../attachments/trip/in-notes.png)',
        ),
      );

      expect(deleted, isEmpty);
    });

    test('does nothing without a configured repo', () async {
      final deleted = <String>[];
      final sync = SyncService(
        localStore: FakeLocalStore(),
        clientFactory: (config) => GitHubClient(
          config,
          client: trackingClient(
            directory: {'attachments/trip/orphan.png': 'sha'},
            deleted: deleted,
          ),
        ),
      );

      await sync.pruneAttachments(
        const GitHubConfig(owner: '', repo: '', branch: 'main', token: ''),
        projectWith(const []),
      );

      expect(deleted, isEmpty);
    });
  });

  group('deleting a project', () {
    test('takes its attachments with it', () async {
      final deleted = <String>[];
      final sync = SyncService(
        localStore: FakeLocalStore(),
        clientFactory: (config) => GitHubClient(
          config,
          client: trackingClient(
            directory: {
              'attachments/trip/one.png': 'sha-one',
              'attachments/trip/two.png': 'sha-two',
            },
            deleted: deleted,
          ),
        ),
      );

      final problem = await sync.deleteRemote(
        testConfig,
        Project(slug: 'trip', title: 'Trip', sha: 'file-sha'),
      );

      expect(problem, isNull);
      expect(deleted, [
        'projects/trip.md',
        'attachments/trip/one.png',
        'attachments/trip/two.png',
      ]);
    });

    test('takes its canvas layout too', () async {
      final deleted = <String>[];
      final sync = SyncService(
        localStore: FakeLocalStore(),
        clientFactory: (config) => GitHubClient(
          config,
          client: trackingClient(
            directory: {
              'canvas/trip.json': 'sha-canvas',
              // Another project's, which must be left alone.
              'canvas/house.json': 'sha-other',
            },
            deleted: deleted,
          ),
        ),
      );

      final problem = await sync.deleteRemote(
        testConfig,
        Project(slug: 'trip', title: 'Trip', sha: 'file-sha'),
      );

      expect(problem, isNull);
      // Left behind, this was orphaned on GitHub for good — and a project
      // later made with the same name would have inherited its canvases.
      expect(deleted, contains('canvas/trip.json'));
      expect(deleted, isNot(contains('canvas/house.json')));
    });

    test('a project with no canvases deletes nothing extra', () async {
      final deleted = <String>[];
      final sync = SyncService(
        localStore: FakeLocalStore(),
        clientFactory: (config) => GitHubClient(
          config,
          client: trackingClient(directory: const {}, deleted: deleted),
        ),
      );

      await sync.deleteRemote(
        testConfig,
        Project(slug: 'trip', title: 'Trip', sha: 'file-sha'),
      );

      expect(deleted, ['projects/trip.md']);
    });
  });
}
