import 'package:actionnotes/models/notes_source.dart';
import 'package:actionnotes/storage/github_client.dart';
import 'package:actionnotes/storage/share_code.dart';
import 'package:flutter_test/flutter_test.dart';

const shared = GitHubConfig(
  owner: 'grahamwheaton',
  repo: 'SharedProjectNotes',
  branch: 'main',
  // The shape of a GitHub fine-grained token, so the code is a realistic
  // length rather than a tidy one.
  token:
      'github_pat_11ABCDEFG0abcdefghijkl_'
      'MNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz0123',
);

void main() {
  group('a share code', () {
    test('carries the repo and the token, and reads back exactly', () {
      final code = ShareCode.encode(shared);
      final again = ShareCode.decode(code);

      expect(again, isNotNull);
      expect(again!.owner, shared.owner);
      expect(again.repo, shared.repo);
      expect(again.branch, shared.branch);
      expect(again.token, shared.token);
    });

    test('says what it is, so it can be told from a pasted anything else', () {
      expect(ShareCode.encode(shared), startsWith('AN1-'));
      expect(ShareCode.looksLikeOne(' AN1-whatever '), isTrue);
      expect(ShareCode.looksLikeOne('https://github.com/x/y'), isFalse);
    });

    test('survives being pasted with space around it', () {
      expect(ShareCode.decode('  ${ShareCode.encode(shared)}\n'), isNotNull);
    });

    test('a code cut short is refused rather than half-read', () {
      final code = ShareCode.encode(shared);
      expect(ShareCode.decode(code.substring(0, code.length - 6)), isNull);
    });

    test('a character mangled in transit is refused', () {
      final code = ShareCode.encode(shared);
      // Swap a character in the middle for a different valid one, the way a
      // chat app might mangle one.
      final at = code.length ~/ 2;
      final swapped = code[at] == 'A' ? 'B' : 'A';
      final damaged = code.replaceRange(at, at + 1, swapped);

      expect(damaged, isNot(code));
      expect(ShareCode.decode(damaged), isNull);
    });

    test('anything that is not one of ours is refused', () {
      expect(ShareCode.decode(''), isNull);
      expect(ShareCode.decode('hello'), isNull);
      expect(ShareCode.decode('AN1-'), isNull);
      expect(ShareCode.decode('AN1-not base64 at all!!'), isNull);
      expect(ShareCode.decode('AN2-${ShareCode.encode(shared)}'), isNull);
    });

    test('a code missing a piece is refused rather than half-configured', () {
      // Everything but the token, which is the piece that makes it work.
      final gutted = ShareCode.encode(
        const GitHubConfig(
          owner: 'graham',
          repo: 'notes',
          branch: 'main',
          token: '',
        ),
      );
      expect(ShareCode.decode(gutted), isNull);
    });

    test('an empty branch becomes main rather than travelling empty', () {
      final code = ShareCode.encode(
        GitHubConfig(
          owner: 'graham',
          repo: 'notes',
          branch: '   ',
          token: shared.token,
        ),
      );
      expect(ShareCode.decode(code)!.branch, 'main');
    });
  });

  group('a source', () {
    test('a shared repo gets the same id however often it is pasted', () {
      expect(NotesSource.idFor(shared), NotesSource.idFor(shared));
      expect(
        NotesSource.idFor(shared),
        'shared-grahamwheaton-sharedprojectnotes',
      );
    });

    test('two different repos get different ids', () {
      const other = GitHubConfig(
        owner: 'grahamwheaton',
        repo: 'OtherNotes',
        branch: 'main',
        token: 'x',
      );
      expect(NotesSource.idFor(other), isNot(NotesSource.idFor(shared)));
    });

    test('is called something a person will recognise', () {
      expect(NotesSource.ownedBy(shared).name, 'My notes');
      expect(NotesSource.sharedFrom(shared).name, 'SharedProjectNotes');
      expect(NotesSource.sharedFrom(shared, label: 'Kitchen').name, 'Kitchen');
      expect(
        NotesSource.sharedFrom(shared).where,
        'grahamwheaton/SharedProjectNotes',
      );
    });

    test('round-trips through preferences without carrying the token', () {
      final source = NotesSource.sharedFrom(shared, label: 'Kitchen');
      final json = source.toJson();

      // The token is not in what goes to ordinary preferences: it belongs in
      // the keystore, and a source written to disk with one in it would be a
      // key left on the side.
      expect(json.toString(), isNot(contains(shared.token)));

      final again = NotesSource.fromJson(json, shared.token);
      expect(again, source);
    });

    test('a source that makes no sense reads back as nothing', () {
      expect(NotesSource.fromJson(const {}, 'token'), isNull);
      expect(NotesSource.fromJson(const {'id': ''}, 'token'), isNull);
      expect(
        NotesSource.fromJson(const {'id': 'x', 'owner': 'a'}, 'token'),
        isNull,
      );
    });
  });
}
