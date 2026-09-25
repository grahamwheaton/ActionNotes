import 'dart:convert';

import 'package:actionnotes/storage/update_check.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fakes.dart';

String releaseJson({required String tag, List<String> assets = const []}) {
  return jsonEncode({
    'tag_name': tag,
    'body': 'Notes for $tag',
    'html_url': 'https://github.com/graham/actionnotes/releases/tag/$tag',
    'assets': [
      for (final name in assets)
        {
          'name': name,
          'browser_download_url': 'https://example.com/$name',
          'digest': 'sha256:${'a' * 64}',
          'size': 123,
        },
    ],
  });
}

UpdateCheck checkerFor(String body, {String? suffix, int status = 200}) {
  return UpdateCheck(
    client: MockClient((_) async => stubResponse(body, status)),
    platformSuffix: suffix,
  );
}

void main() {
  group('comparing versions', () {
    test('a higher version is newer', () {
      expect(UpdateCheck.isNewer('0.9.0', '0.8.0'), isTrue);
      expect(UpdateCheck.isNewer('1.0.0', '0.9.9'), isTrue);
    });

    test('the same version is not', () {
      expect(UpdateCheck.isNewer('0.8.0', '0.8.0'), isFalse);
      expect(UpdateCheck.isNewer('0.8.0', '0.9.0'), isFalse);
    });

    // A string comparison gets this wrong, and this project will reach it.
    test('ten is newer than nine', () {
      expect(UpdateCheck.isNewer('0.10.0', '0.9.0'), isTrue);
      expect(UpdateCheck.isNewer('0.9.0', '0.10.0'), isFalse);
    });

    test('the build number is not part of it', () {
      expect(UpdateCheck.isNewer('0.8.0+99', '0.8.0+1'), isFalse);
    });

    test('a missing part counts as zero', () {
      expect(UpdateCheck.isNewer('0.9', '0.8.7'), isTrue);
      expect(UpdateCheck.isNewer('0.8', '0.8.0'), isFalse);
    });
  });

  group('asking GitHub', () {
    test('offers the platform asset for a newer release', () async {
      final checker = checkerFor(
        releaseJson(
          tag: 'v0.9.0',
          assets: ['actionnotes-v0.9.0.apk', 'actionnotes-v0.9.0-windows.zip'],
        ),
        suffix: '.apk',
      );

      final update = await checker.latest('0.8.0');

      expect(update, isNotNull);
      expect(update!.version, '0.9.0');
      expect(update.downloadName, 'actionnotes-v0.9.0.apk');
      expect(update.downloadUrl, endsWith('.apk'));
      expect(update.downloadDigest, 'sha256:${'a' * 64}');
      expect(update.downloadSize, 123);
      expect(update.notes, contains('v0.9.0'));
    });

    test('picks the Windows asset on Windows', () async {
      final checker = checkerFor(
        releaseJson(
          tag: 'v0.9.0',
          assets: ['actionnotes-v0.9.0.apk', 'actionnotes-v0.9.0-windows.zip'],
        ),
        suffix: '-windows.zip',
      );

      expect(
        (await checker.latest('0.8.0'))!.downloadName,
        'actionnotes-v0.9.0-windows.zip',
      );
    });

    test('says nothing when the running build is current', () async {
      final checker = checkerFor(releaseJson(tag: 'v0.8.0'), suffix: '.apk');
      expect(await checker.latest('0.8.0'), isNull);
    });

    test(
      'a release without an asset for this platform still offers the page',
      () async {
        final checker = checkerFor(
          releaseJson(tag: 'v0.9.0', assets: ['actionnotes-v0.9.0.apk']),
          suffix: '-linux.tar.gz',
        );

        final update = await checker.latest('0.8.0');

        expect(update!.downloadUrl, isNull);
        expect(update.pageUrl, contains('releases/tag/v0.9.0'));
      },
    );

    // An update check is a convenience: it must never be the reason the app
    // shows an error.
    test('a failure is silent', () async {
      expect(
        await checkerFor('nope', status: 500, suffix: '.apk').latest('0.8.0'),
        isNull,
      );
      expect(
        await checkerFor('<html>', suffix: '.apk').latest('0.8.0'),
        isNull,
      );
      expect(
        await UpdateCheck(
          client: MockClient((_) async => throw Exception('offline')),
          platformSuffix: '.apk',
        ).latest('0.8.0'),
        isNull,
      );
    });

    test('an unauthenticated request is enough', () async {
      late http.Request seen;
      final checker = UpdateCheck(
        client: MockClient((request) async {
          seen = request;
          return stubResponse(releaseJson(tag: 'v0.9.0'), 200);
        }),
        platformSuffix: '.apk',
      );

      await checker.latest('0.8.0');

      // No token: the check has to work before anyone has signed in, which is
      // when a stale build is most likely.
      expect(seen.headers.containsKey('Authorization'), isFalse);
      expect(seen.url.path, endsWith('/releases/latest'));
    });
  });
}
