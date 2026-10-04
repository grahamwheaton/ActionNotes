import 'dart:convert';
import 'dart:io';

import 'package:actionnotes/storage/folder_store.dart';
import 'package:actionnotes/storage/remote_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late FolderStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('actionnotes-folder-store');
    FolderStore.forgetAll();
    store = FolderStore(FolderConfig(path: root.path));
  });

  tearDown(() {
    FolderStore.forgetAll();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> expectRefused(Future<Object?> attempt, int status) async {
    try {
      await attempt;
      fail('expected a $status');
    } on StoreException catch (error) {
      expect(error.statusCode, status);
    }
  }

  group('reading and writing', () {
    test('a file written can be read back with the revision it was given',
        () async {
      final sha = await store.writeFile(
        path: 'projects/trip.md',
        content: '# Trip\n',
        message: 'Update Trip',
      );

      final file = await store.readFile('projects/trip.md');

      expect(file, isNotNull);
      expect(file!.content, '# Trip\n');
      expect(file.sha, sha);
    });

    test('a file that is not there is null, not an error', () async {
      expect(await store.readFile('projects/nothing.md'), isNull);
      expect(await store.readBytes('attachments/x/y.png'), isNull);
    });

    test('folders are made as needed, and nothing is left beside the file',
        () async {
      await store.writeBytes(
        path: 'attachments/trip/photo.png',
        bytes: const [1, 2, 3, 4],
        message: 'Add attachment',
      );

      expect(await store.readBytes('attachments/trip/photo.png'), [1, 2, 3, 4]);
      final names = Directory('${root.path}/attachments/trip')
          .listSync()
          .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
          .toList();
      expect(names, ['photo.png']);
    });

    test('text keeps its accents and symbols', () async {
      const text = 'Café — naïve ✓ 日本語\n';
      await store.writeFile(
        path: 'projects/unicode.md',
        content: text,
        message: 'x',
      );

      expect((await store.readFile('projects/unicode.md'))!.content, text);
    });
  });

  group('revisions stand in for GitHub\'s SHA', () {
    test('a stale revision is refused with a 409', () async {
      final first = await store.writeFile(
        path: 'projects/trip.md',
        content: 'one',
        message: 'x',
      );
      // Somebody else — a cloud app delivering another device's edit.
      File('${root.path}/projects/trip.md').writeAsStringSync('two');

      await expectRefused(
        store.writeFile(
          path: 'projects/trip.md',
          content: 'three',
          message: 'x',
          sha: first,
        ),
        409,
      );
      expect(File('${root.path}/projects/trip.md').readAsStringSync(), 'two');
    });

    test('writing over a file without naming its revision is a 422', () async {
      await store.writeFile(path: 'projects/a.md', content: 'x', message: 'x');

      await expectRefused(
        store.writeFile(path: 'projects/a.md', content: 'y', message: 'x'),
        422,
      );
    });

    test('the current revision is accepted, and gives a new one', () async {
      final first = await store.writeFile(
        path: 'projects/a.md',
        content: 'one',
        message: 'x',
      );
      final second = await store.writeFile(
        path: 'projects/a.md',
        content: 'two',
        message: 'x',
        sha: first,
      );

      expect(second, isNot(first));
      expect((await store.readFile('projects/a.md'))!.sha, second);
    });

    test('a revision for a file deleted elsewhere recreates it', () async {
      final first = await store.writeFile(
        path: 'projects/a.md',
        content: 'one',
        message: 'x',
      );
      File('${root.path}/projects/a.md').deleteSync();

      await store.writeFile(
        path: 'projects/a.md',
        content: 'mine',
        message: 'x',
        sha: first,
      );

      expect(File('${root.path}/projects/a.md').readAsStringSync(), 'mine');
    });

    test('the same content has the same revision wherever it is', () async {
      final a = await store.writeFile(
        path: 'projects/a.md',
        content: 'same',
        message: 'x',
      );
      final b = await store.writeFile(
        path: 'projects/b.md',
        content: 'same',
        message: 'x',
      );

      expect(a, b);
    });
  });

  group('listing', () {
    test('only markdown files are projects, and each has its revision',
        () async {
      final sha = await store.writeFile(
        path: 'projects/trip.md',
        content: 'one',
        message: 'x',
      );
      File('${root.path}/projects/notes.txt').writeAsStringSync('no');
      File('${root.path}/projects/.hidden.md').writeAsStringSync('no');
      File('${root.path}/projects/.trip.md.partial').writeAsStringSync('no');
      Directory('${root.path}/projects/sub').createSync();

      final listing = await store.listProjects();

      expect(listing.map((e) => e.path), ['projects/trip.md']);
      expect(listing.single.sha, sha);
    });

    test('an edit made outside the app changes the revision', () async {
      await store.writeFile(
        path: 'projects/a.md',
        content: 'aaa',
        message: 'x',
      );
      final before = (await store.listProjects()).single.sha;

      // The same length, so only a changed modified time can give it away.
      final file = File('${root.path}/projects/a.md')
        ..writeAsStringSync('bbb')
        ..setLastModifiedSync(DateTime.now().add(const Duration(minutes: 5)));
      expect(file.lengthSync(), 3);

      final after = (await store.listProjects()).single.sha;
      expect(after, isNot(before));
    });

    test('a folder listing gives full paths and revisions', () async {
      final sha = await store.writeBytes(
        path: 'attachments/trip/a.png',
        bytes: utf8.encode('img'),
        message: 'x',
      );

      expect(await store.listDirectory('attachments/trip'), {
        'attachments/trip/a.png': sha,
      });
      expect(await store.listDirectory('attachments/none'), isEmpty);
    });

    test('a missing projects folder is an error, not an empty notebook',
        () async {
      // Otherwise a cloud drive that is not mounted looks like every project
      // having been deleted, and the sync clears the copies it holds.
      await expectRefused(store.listProjects(), 404);
    });

    test('an empty projects folder is simply no projects', () async {
      Directory('${root.path}/projects').createSync();

      expect(await store.listProjects(), isEmpty);
    });
  });

  group('deleting', () {
    test('needs the current revision', () async {
      final sha = await store.writeFile(
        path: 'projects/a.md',
        content: 'one',
        message: 'x',
      );

      await expectRefused(
        store.deleteFile(path: 'projects/a.md', sha: 'old', message: 'x'),
        409,
      );
      expect(File('${root.path}/projects/a.md').existsSync(), isTrue);

      await store.deleteFile(path: 'projects/a.md', sha: sha, message: 'x');
      expect(File('${root.path}/projects/a.md').existsSync(), isFalse);
    });

    test('a file that is not there is a 404', () async {
      await expectRefused(
        store.deleteFile(path: 'projects/gone.md', sha: 'x', message: 'x'),
        404,
      );
    });
  });

  group('access', () {
    test('a folder that exists is fine', () async {
      await store.checkAccess();
    });

    test('a folder that has gone says so, and is not worth retrying', () async {
      root.deleteSync(recursive: true);

      try {
        await store.checkAccess();
        fail('expected a refusal');
      } on StoreException catch (error) {
        expect(error.statusCode, 404);
        expect(error.isFatal, isTrue);
      }
    });

    test('it will not vouch for being private', () async {
      expect(await store.repoIsPrivate(), isFalse);
    });
  });
}
