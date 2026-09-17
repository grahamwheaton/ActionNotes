import 'package:actionnotes/storage/github_account.dart';
import 'package:actionnotes/storage/github_client.dart';
import 'package:actionnotes/ui/repo_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const repos = [
  RepoRef(owner: 'grahamwheaton', name: 'ActionNotes', defaultBranch: 'main'),
  RepoRef(owner: 'grahamwheaton', name: 'ProjectNotes', defaultBranch: 'master'),
  RepoRef(owner: 'acme', name: 'notes-archive', defaultBranch: 'main'),
];

/// Opens the picker over a bare app and hands back what it returned.
Future<RepoRef?> open(
  WidgetTester tester,
  Future<List<RepoRef>> Function() load,
) async {
  RepoRef? picked;
  var opened = false;

  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () async {
              opened = true;
              picked = await showRepoPicker(context, load: load);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(opened, isTrue);
  return picked;
}

void main() {
  testWidgets('lists what the token can reach', (tester) async {
    await open(tester, () async => repos);

    expect(find.text('grahamwheaton/ActionNotes'), findsOneWidget);
    expect(find.text('grahamwheaton/ProjectNotes'), findsOneWidget);
    expect(find.text('acme/notes-archive'), findsOneWidget);
    // The branch is shown, because picking a repo sets it too.
    expect(find.text('master'), findsOneWidget);
  });

  testWidgets('searching narrows on the whole owner/name', (tester) async {
    await open(tester, () async => repos);

    await tester.enterText(find.byType(TextField), 'project');
    await tester.pump();

    expect(find.text('grahamwheaton/ProjectNotes'), findsOneWidget);
    expect(find.text('grahamwheaton/ActionNotes'), findsNothing);

    await tester.enterText(find.byType(TextField), 'acme');
    await tester.pump();

    expect(find.text('acme/notes-archive'), findsOneWidget);
    expect(find.text('grahamwheaton/ProjectNotes'), findsNothing);
  });

  testWidgets('says so when nothing matches', (tester) async {
    await open(tester, () async => repos);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump();

    expect(find.textContaining('Nothing matches'), findsOneWidget);
  });

  testWidgets('picking one returns it', (tester) async {
    RepoRef? picked;

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async =>
                  picked = await showRepoPicker(context, load: () async => repos),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('grahamwheaton/ProjectNotes'));
    await tester.pumpAndSettle();

    expect(picked?.fullName, 'grahamwheaton/ProjectNotes');
    expect(picked?.defaultBranch, 'master');
  });

  testWidgets('dismissing keeps whatever was typed, by returning nothing',
      (tester) async {
    final picked = await open(tester, () async => repos);
    expect(picked, isNull);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('grahamwheaton/ActionNotes'), findsNothing);
  });

  // An empty list is the shape of the mistake worth naming: signing in and
  // installing the app are separate steps, and only the second grants access.
  testWidgets('an empty list explains the install step', (tester) async {
    await open(tester, () async => const []);

    expect(find.textContaining('Install ActionNotes on the repo'), findsOneWidget);
  });

  testWidgets('a failure can be retried without reopening', (tester) async {
    var attempts = 0;

    await open(tester, () async {
      attempts++;
      if (attempts == 1) throw GitHubException(401, 'Bad credentials');
      return repos;
    });

    expect(find.text('Token rejected. Sign in again.'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('grahamwheaton/ActionNotes'), findsOneWidget);
  });
}
