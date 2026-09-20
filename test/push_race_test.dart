import 'dart:async';
import 'dart:convert';

import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/storage/github_client.dart';
import 'package:actionnotes/storage/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fakes.dart';

/// A repo that enforces SHAs the way GitHub does: a write is accepted only
/// against the SHA the file currently has, and rejected with 409 otherwise.
///
/// That check is the whole point — a conflict the app reports is this refusal,
/// so a stub that waves writes through cannot show whether one was deserved.
class FakeRepo {
  final Map<String, String> _shas = {};
  final Map<String, String> contents = {};
  int _counter = 0;

  /// The SHA each write was sent with, in order.
  final List<String?> sent = [];

  /// Writes GitHub refused because the SHA had moved on.
  int rejected = 0;

  /// Set to hold writes open, so a test can edit while one is in flight.
  Completer<void>? gate;

  /// How many writes are inside the gate at once. More than one at a time is
  /// the race itself.
  int inFlight = 0;
  int mostAtOnce = 0;

  String shaOf(String path) => _shas[path] ?? 'none';

  http.Client client() {
    return MockClient((request) async {
      final path = Uri.decodeFull(request.url.path).split('/contents/').last;

      if (request.method == 'PUT') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final with_ = body['sha'] as String?;
        sent.add(with_);

        inFlight++;
        mostAtOnce = inFlight > mostAtOnce ? inFlight : mostAtOnce;
        try {
          final hold = gate;
          if (hold != null) await hold.future;

          if (_shas[path] != with_) {
            rejected++;
            return stubResponse(
              jsonEncode({
                'message': 'is at ${_shas[path]} but expected $with_',
              }),
              409,
            );
          }

          final next = 'sha-${++_counter}';
          _shas[path] = next;
          contents[path] = utf8.decode(
            base64.decode((body['content'] as String)),
          );
          return stubResponse(
            jsonEncode({
              'content': {'sha': next},
            }),
            200,
          );
        } finally {
          inFlight--;
        }
      }

      // Nothing else matters here: an empty projects listing and no
      // attachments keep the pull and the prune quiet.
      return stubResponse('[]', 200);
    });
  }
}

/// A state whose edits settle almost at once, so a test is not two seconds
/// per keystroke.
AppState stateFor(FakeRepo repo, FakeLocalStore store) => AppState(
  localStore: store,
  settingsStore: FakeSettingsStore(config: testConfig),
  syncService: SyncService(
    localStore: store,
    clientFactory: (config) => GitHubClient(config, client: repo.client()),
  ),
  pushDelay: const Duration(milliseconds: 20),
);

/// Lets the debounce fire and the push finish.
Future<void> settle([int ms = 120]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  test(
    'an ordinary edit pushes once and keeps the SHA it came back with',
    () async {
      final repo = FakeRepo();
      final store = FakeLocalStore();
      final state = stateFor(repo, store);
      await state.init();

      await state.createProject('List');
      await state.addItem('list', 'First');
      await settle();

      expect(repo.rejected, 0);
      expect(state.projects.single.sha, repo.shaOf('projects/list.md'));
      expect(state.projects.single.dirty, isFalse);
    },
  );

  // The reported symptom: "it says GitHub is different to local, but nothing
  // else has touched it". Typing while a push is in flight was enough.
  test('an edit made during a push does not turn into a conflict', () async {
    final repo = FakeRepo();
    final store = FakeLocalStore();
    final state = stateFor(repo, store);
    await state.init();

    await state.createProject('List');
    await state.addItem('list', 'First');
    await settle();

    // Hold the next write open, edit while it is in the air, then let go.
    repo.gate = Completer<void>();
    await state.setItemNotes('list', 0, 'typed before the push landed');
    await settle(60);
    await state.setItemNotes('list', 0, 'typed while the push was in flight');
    repo.gate!.complete();
    repo.gate = null;
    await settle(300);

    expect(repo.rejected, 0, reason: 'no write should have been refused');
    expect(
      state.message,
      isNull,
      reason: 'nothing to report and nothing to ask',
    );
    expect(state.projects.single.dirty, isFalse);
    // Both the file and the app agree, and on the later text.
    expect(state.projects.single.sha, repo.shaOf('projects/list.md'));
    expect(
      repo.contents['projects/list.md'],
      contains('typed while the push was in flight'),
    );
  });

  test('a successful push never leaves a SHA behind it', () async {
    final repo = FakeRepo();
    final store = FakeLocalStore();
    final state = stateFor(repo, store);
    await state.init();

    await state.createProject('List');
    await state.addItem('list', 'First');
    await settle();

    repo.gate = Completer<void>();
    await state.addItem('list', 'Second');
    await settle(60);
    // The edit that used to cost the push its SHA.
    await state.addItem('list', 'Third');
    repo.gate!.complete();
    repo.gate = null;
    await settle(300);

    // Whatever else happened, the next write must be sent with the SHA the
    // file actually has.
    expect(repo.sent.last, isNot('none'));
    expect(state.projects.single.sha, repo.shaOf('projects/list.md'));
    expect(store.saved['list']!.sha, repo.shaOf('projects/list.md'));
  });

  test('two pushes of one project never overlap', () async {
    final repo = FakeRepo();
    final store = FakeLocalStore();
    final state = stateFor(repo, store);
    await state.init();

    await state.createProject('List');
    await state.addItem('list', 'First');
    await settle();

    repo.gate = Completer<void>();
    await state.addItem('list', 'Second');
    await settle(60);
    await state.addItem('list', 'Third');
    await settle(60);
    await state.addItem('list', 'Fourth');
    repo.gate!.complete();
    repo.gate = null;
    await settle(400);

    expect(repo.mostAtOnce, 1);
    expect(repo.rejected, 0);
  });

  test(
    'edits while a push is in flight are coalesced, not one commit each',
    () async {
      final repo = FakeRepo();
      final store = FakeLocalStore();
      final state = stateFor(repo, store);
      await state.init();

      await state.createProject('List');
      await state.addItem('list', 'First');
      await settle();

      final before = repo.sent.length;
      repo.gate = Completer<void>();
      await state.addItem('list', 'Second');
      await settle(60);
      await state.addItem('list', 'Third');
      await state.addItem('list', 'Fourth');
      repo.gate!.complete();
      repo.gate = null;
      await settle(400);

      // The held write, then one more carrying everything typed since.
      expect(repo.sent.length - before, 2);
      expect(repo.contents['projects/list.md'], contains('Fourth'));
    },
  );
}
