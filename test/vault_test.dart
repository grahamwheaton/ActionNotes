import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:actionnotes/storage/folder_backend.dart';
import 'package:actionnotes/storage/vault.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late Vault vault;

  setUp(() {
    root = Directory.systemTemp.createTempSync('actionnotes-vault');
    vault = Vault(IoFolderBackend(root.path));
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('looking at a folder', () {
    test('an empty folder has nothing of ours in it', () async {
      final probe = await vault.probe();

      expect(probe.state, FolderState.empty);
      expect(probe.exists, isFalse);
      expect(probe.projects, 0);
    });

    test('a folder with projects but no identity is unmarked', () async {
      Directory('${root.path}/projects').createSync();
      File('${root.path}/projects/a.md').writeAsStringSync('# A');
      File('${root.path}/projects/b.md').writeAsStringSync('# B');
      File('${root.path}/projects/readme.txt').writeAsStringSync('no');

      final probe = await vault.probe();

      expect(probe.state, FolderState.unmarked);
      expect(probe.projects, 2);
    });

    test('looking changes nothing', () async {
      await vault.probe();

      expect(root.listSync(), isEmpty);
    });
  });

  group('setting up', () {
    test('adds a projects folder and an identity, and nothing else', () async {
      File('${root.path}/holiday-photo.jpg').writeAsStringSync('keep me');

      final info = await vault.open(name: 'Work');

      expect(info.name, 'Work');
      expect(Directory('${root.path}/projects').existsSync(), isTrue);
      expect(
        File('${root.path}/.actionnotes/vault.json').existsSync(),
        isTrue,
      );
      expect(
        File('${root.path}/holiday-photo.jpg').readAsStringSync(),
        'keep me',
      );
      final top = root.listSync().map((e) => e.path.split(Platform.pathSeparator).last);
      expect(
        top.toSet(),
        {'holiday-photo.jpg', 'projects', '.actionnotes'},
      );
    });

    test('opening it again finds the same notebook', () async {
      final first = await vault.open(name: 'Work');
      final second = await vault.open(name: 'Something else');

      expect(second.id, first.id);
      expect(second.name, 'Work');
    });

    test('a second device connecting gets the first one\'s identity', () async {
      final first = await vault.open(name: 'Family');

      final other = Vault(IoFolderBackend(root.path));
      final probe = await other.probe();

      expect(probe.state, FolderState.notebook);
      expect(probe.info!.id, first.id);
    });

    test('existing projects are kept and the folder is given an identity',
        () async {
      Directory('${root.path}/projects').createSync();
      File('${root.path}/projects/a.md').writeAsStringSync('# A');

      final info = await vault.open(name: 'Imported');

      expect(info.name, 'Imported');
      expect(File('${root.path}/projects/a.md').readAsStringSync(), '# A');
      expect((await vault.probe()).state, FolderState.notebook);
    });

    test('the projects folder is restored if only the identity survived',
        () async {
      await vault.open(name: 'Work');
      Directory('${root.path}/projects').deleteSync(recursive: true);

      await vault.open(name: 'Work');

      expect(Directory('${root.path}/projects').existsSync(), isTrue);
    });
  });

  group('the identity file', () {
    test('survives a round trip', () {
      final info = VaultInfo(
        id: 'abc123def456',
        name: 'Work',
        created: DateTime.utc(2026, 10, 4, 12),
      );

      final back = VaultInfo.parse(info.serialize())!;

      expect(back.id, 'abc123def456');
      expect(back.name, 'Work');
      expect(back.created, DateTime.utc(2026, 10, 4, 12));
    });

    test('one that is not ours, or is damaged, is no identity at all', () {
      expect(VaultInfo.parse('not json'), isNull);
      expect(VaultInfo.parse('[]'), isNull);
      expect(VaultInfo.parse('{}'), isNull);
    });

    test('an id that could escape a folder name is refused', () {
      for (final id in ['../x', 'a/b', 'a b', '', 'short', r'a\b\c\d\e\f']) {
        expect(
          VaultInfo.parse(jsonEncode({'id': id, 'name': 'x'})),
          isNull,
          reason: id,
        );
      }
    });

    test('a damaged one is replaced rather than trusted', () async {
      Directory('${root.path}/.actionnotes').createSync();
      File('${root.path}/.actionnotes/vault.json').writeAsStringSync('{{');

      final info = await vault.open(name: 'Work');

      expect(VaultInfo.parse(
        File('${root.path}/.actionnotes/vault.json').readAsStringSync(),
      )!.id, info.id);
    });

    test('generated ids are valid and differ', () {
      final random = Random(7);
      final a = VaultInfo.newId(random);
      final b = VaultInfo.newId(random);

      expect(a, isNot(b));
      expect(VaultInfo.parse(jsonEncode({'id': a, 'name': ''})), isNotNull);
    });
  });
}
