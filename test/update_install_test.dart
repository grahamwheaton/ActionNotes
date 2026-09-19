import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:actionnotes/state/app_state.dart';
import 'package:actionnotes/storage/sync_service.dart';
import 'package:actionnotes/storage/update_check.dart';
import 'package:actionnotes/storage/update_installer.dart';
import 'package:actionnotes/ui/theme.dart';
import 'package:actionnotes/ui/update_banner.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'support/fakes.dart';

const anUpdate = AvailableUpdate(
  version: '0.14.0',
  notes: 'Notes',
  pageUrl: 'https://example.com/releases/v0.14.0',
  downloadUrl: 'https://example.com/actionnotes-v0.14.0.apk',
  downloadName: 'actionnotes-v0.14.0.apk',
);

/// A release with no file for this platform, so only the page is on offer.
const pageOnly = AvailableUpdate(
  version: '0.14.0',
  notes: 'Notes',
  pageUrl: 'https://example.com/releases/v0.14.0',
);

/// Serves [body] in two chunks, so the progress reported is something a test
/// can watch move rather than jump from nothing to done.
http.Client serving(List<int> body, {int status = 200, int? contentLength}) {
  return MockClient.streaming((_, __) async {
    final half = body.length ~/ 2;
    return http.StreamedResponse(
      Stream.fromIterable([body.sublist(0, half), body.sublist(half)]),
      status,
      contentLength: contentLength ?? body.length,
    );
  });
}

UpdateInstaller installerFor(
  http.Client client,
  Directory into, {
  Future<bool> Function(String path)? open,
}) {
  return UpdateInstaller(
    client: client,
    directory: () async => into,
    open: open ?? (_) async => true,
  );
}

Directory tempDirectory() {
  final directory = Directory.systemTemp.createTempSync('actionnotes-update');
  addTearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  return directory;
}

void main() {
  group('fetching an update', () {
    test('writes the file and reports how far along it is', () async {
      final into = tempDirectory();
      final body = List<int>.filled(100, 7);
      final progress = <double>[];

      final file = await installerFor(
        serving(body),
        into,
      ).fetch(anUpdate, onProgress: progress.add);

      expect(file, isNotNull);
      expect(file!.readAsBytesSync(), body);
      // Named for the release, so a half-finished download of one version is
      // never mistaken for another.
      expect(file.path, endsWith('actionnotes-v0.14.0.apk'));
      expect(progress.first, lessThan(1));
      expect(progress.last, 1);
    });

    test('a release with no file for this platform fetches nothing', () async {
      final into = tempDirectory();
      final file = await installerFor(serving([1, 2, 3]), into).fetch(pageOnly);
      expect(file, isNull);
    });

    test('a refusal is null rather than a broken file', () async {
      final into = tempDirectory();
      final file = await installerFor(
        serving([1, 2, 3], status: 404),
        into,
      ).fetch(anUpdate);

      expect(file, isNull);
      expect(Directory('${into.path}/updates').existsSync(), isFalse);
    });

    test('a download that stops short is thrown away, not handed on', () async {
      final into = tempDirectory();
      // The server promised a hundred bytes and sent ten.
      final file = await installerFor(
        serving(List<int>.filled(10, 1), contentLength: 100),
        into,
      ).fetch(anUpdate);

      // Android would call a truncated package corrupt, which says nothing
      // about the lost connection that actually caused it.
      expect(file, isNull);
      expect(Directory('${into.path}/updates').listSync(), isEmpty);
    });

    test('a connection that fails is null rather than an exception', () async {
      final into = tempDirectory();
      final file = await installerFor(
        MockClient.streaming((_, __) => throw const SocketException('no')),
        into,
      ).fetch(anUpdate);

      expect(file, isNull);
    });

    test('tidying takes the downloads away', () async {
      final into = tempDirectory();
      final installer = installerFor(serving(List<int>.filled(20, 3)), into);

      await installer.fetch(anUpdate);
      expect(Directory('${into.path}/updates').existsSync(), isTrue);

      await installer.tidy();
      expect(Directory('${into.path}/updates').existsSync(), isFalse);
    });
  });

  group('handing it to the system', () {
    test('says whether it was taken', () async {
      final into = tempDirectory();
      final file = File('${into.path}/x.apk')..writeAsStringSync('x');

      expect(
        await installerFor(
          serving([1]),
          into,
          open: (_) async => true,
        ).install(file),
        isTrue,
      );
      expect(
        await installerFor(
          serving([1]),
          into,
          open: (_) async => throw const FileSystemException('no'),
        ).install(file),
        isFalse,
      );
    });
  });

  group('the banner', () {
    /// Drives the app to the point where it is actually offering an update,
    /// rather than reaching in and setting one: what the banner does depends
    /// on what the release turned out to have in it.
    Future<AppState> pumpBanner(
      WidgetTester tester, {
      required UpdateInstaller? installer,
      bool withFile = true,
    }) async {
      PackageInfo.setMockInitialValues(
        appName: 'ActionNotes',
        packageName: 'uk.actionnotes',
        version: '0.13.0',
        buildNumber: '29',
        buildSignature: '',
      );

      final store = FakeLocalStore();
      final state = AppState(
        localStore: store,
        settingsStore: FakeSettingsStore(),
        syncService: SyncService(localStore: store),
        updateCheck: UpdateCheck(
          client: MockClient(
            (_) async => stubResponse(
              jsonEncode({
                'tag_name': 'v0.14.0',
                'body': 'Notes',
                'html_url': 'https://example.com/releases/v0.14.0',
                'assets': [
                  {
                    'name': 'actionnotes-v0.14.0.apk',
                    'browser_download_url':
                        'https://example.com/actionnotes-v0.14.0.apk',
                  },
                ],
              }),
              200,
            ),
          ),
          platformSuffix: withFile ? '.apk' : null,
        ),
      );
      await state.init();
      await state.checkForUpdate();

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(body: UpdateBanner(installer: installer)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return state;
    }

    testWidgets('offers Install where the system can take the file', (
      tester,
    ) async {
      await pumpBanner(tester, installer: _FakeInstaller());

      expect(find.text('Version 0.14.0 is out.'), findsOneWidget);
      expect(find.text('Install'), findsOneWidget);
    });

    testWidgets('downloads, shows how far along, and hands it over', (
      tester,
    ) async {
      final installer = _FakeInstaller();
      await pumpBanner(tester, installer: installer);

      await tester.tap(find.text('Install'));
      await tester.pump();

      // What it says while it works: a number, because an APK is sixty
      // megabytes and "working…" says nothing about whether it is worth
      // waiting for.
      installer.report(0.4);
      await tester.pump();
      expect(find.textContaining('Downloading 0.14.0… 40%'), findsOneWidget);
      // And nothing can be dismissed out from under a running download.
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byIcon(Icons.close),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );

      installer.finish();
      await tester.pumpAndSettle();

      expect(installer.handed, endsWith('actionnotes-v0.14.0.apk'));
      // Back to the offer once it is out of our hands: Android takes it from
      // there, and an update offered and not taken is still one waiting.
      expect(find.text('Install'), findsOneWidget);
    });

    testWidgets('says so when the download fails, and keeps the offer', (
      tester,
    ) async {
      final installer = _FakeInstaller();
      await pumpBanner(tester, installer: installer);

      await tester.tap(find.text('Install'));
      await tester.pump();
      installer.fail();
      await tester.pumpAndSettle();

      expect(find.text('Could not download the update.'), findsOneWidget);
      expect(find.text('Install'), findsOneWidget);
    });

    testWidgets('a release with no file for this platform opens the page', (
      tester,
    ) async {
      await pumpBanner(tester, installer: null, withFile: false);

      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Install'), findsNothing);
    });
  });
}

/// Stands in for the real installer in a widget test.
///
/// The real one writes to a real disk, and a widget test's clock never lets
/// that finish — so the downloading is tested on its own above, and here the
/// banner is driven directly through the steps it has to show.
class _FakeInstaller extends UpdateInstaller {
  _FakeInstaller()
    : super(client: MockClient((_) async => http.Response('', 404)));

  final _completer = Completer<File?>();
  void Function(double)? _onProgress;

  /// What was handed to the system, or empty if nothing was.
  String handed = '';

  void report(double progress) => _onProgress?.call(progress);

  void finish() => _completer.complete(
    File('/tmp/actionnotes/updates/actionnotes-v0.14.0.apk'),
  );

  void fail() => _completer.complete(null);

  @override
  Future<File?> fetch(
    AvailableUpdate update, {
    void Function(double progress)? onProgress,
  }) {
    _onProgress = onProgress;
    return _completer.future;
  }

  @override
  Future<bool> install(File file) async {
    handed = file.path;
    return true;
  }
}
