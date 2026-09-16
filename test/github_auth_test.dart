import 'dart:convert';

import 'package:actionnotes/storage/github_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A started sign-in, with no wait between polls so the tests stay quick.
String codeResponse({int interval = 0, int expiresIn = 900}) => jsonEncode({
      'device_code': 'dev-code',
      'user_code': 'WDJB-MJHT',
      'verification_uri': 'https://github.com/login/device',
      'interval': interval,
      'expires_in': expiresIn,
    });

void main() {
  test('a started sign-in carries the code a person has to type', () async {
    final flow = GitHubDeviceFlow(
      client: MockClient((_) async => http.Response(codeResponse(interval: 5), 200)),
    );

    final code = await flow.start();

    expect(code.userCode, 'WDJB-MJHT');
    expect(code.deviceCode, 'dev-code');
    expect(code.verificationUri.toString(), 'https://github.com/login/device');
    expect(code.interval, const Duration(seconds: 5));
    expect(code.hasExpired, isFalse);
  });

  test('the client id is sent, and no secret alongside it', () async {
    late http.Request seen;
    final flow = GitHubDeviceFlow(
      client: MockClient((request) async {
        seen = request;
        return http.Response(codeResponse(), 200);
      }),
    );

    await flow.start();

    expect(seen.bodyFields['client_id'], githubClientId);
    expect(seen.bodyFields.containsKey('client_secret'), isFalse);
  });

  test('polling waits for approval, then hands back the token', () async {
    var polls = 0;
    final flow = GitHubDeviceFlow(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/device/code')) {
          return http.Response(codeResponse(), 200);
        }

        polls++;
        // GitHub answers "not yet" until somebody clicks approve.
        if (polls < 3) {
          return http.Response(jsonEncode({'error': 'authorization_pending'}), 200);
        }
        return http.Response(jsonEncode({'access_token': 'gho_token'}), 200);
      }),
    );

    final token = await flow.awaitToken(await flow.start());

    expect(token, 'gho_token');
    expect(polls, 3);
  });

  test('the poll asks for a device-flow grant against the right code', () async {
    late http.Request seen;
    final flow = GitHubDeviceFlow(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/device/code')) {
          return http.Response(codeResponse(), 200);
        }
        seen = request;
        return http.Response(jsonEncode({'access_token': 'gho_token'}), 200);
      }),
    );

    await flow.awaitToken(await flow.start());

    expect(seen.bodyFields['device_code'], 'dev-code');
    expect(
      seen.bodyFields['grant_type'],
      'urn:ietf:params:oauth:grant-type:device_code',
    );
  });

  test('a slow_down backs off rather than failing', () async {
    var polls = 0;
    final flow = GitHubDeviceFlow(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/device/code')) {
          return http.Response(codeResponse(), 200);
        }

        polls++;
        if (polls == 1) {
          return http.Response(
            jsonEncode({'error': 'slow_down', 'interval': 0}),
            200,
          );
        }
        return http.Response(jsonEncode({'access_token': 'gho_token'}), 200);
      }),
    );

    expect(await flow.awaitToken(await flow.start()), 'gho_token');
    expect(polls, 2);
  });

  test('refusing on GitHub reads as cancelled, not as an error', () async {
    final flow = GitHubDeviceFlow(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/device/code')) {
          return http.Response(codeResponse(), 200);
        }
        return http.Response(jsonEncode({'error': 'access_denied'}), 200);
      }),
    );

    await expectLater(
      flow.awaitToken(await flow.start()),
      throwsA(isA<GitHubAuthException>().having((e) => e.isCancelled, 'isCancelled', isTrue)),
    );
  });

  test('an expired code says to start again', () async {
    final flow = GitHubDeviceFlow(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/device/code')) {
          return http.Response(codeResponse(), 200);
        }
        return http.Response(jsonEncode({'error': 'expired_token'}), 200);
      }),
    );

    await expectLater(
      flow.awaitToken(await flow.start()),
      throwsA(isA<GitHubAuthException>()
          .having((e) => e.message, 'message', contains('expired'))
          .having((e) => e.isCancelled, 'isCancelled', isFalse)),
    );
  });

  test('a code that ran out of time is not polled at all', () async {
    var polls = 0;
    final flow = GitHubDeviceFlow(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/device/code')) {
          return http.Response(codeResponse(expiresIn: -1), 200);
        }
        polls++;
        return http.Response(jsonEncode({'access_token': 'gho_token'}), 200);
      }),
    );

    await expectLater(
      flow.awaitToken(await flow.start()),
      throwsA(isA<GitHubAuthException>()),
    );
    expect(polls, 0);
  });

  test('cancelling stops the polling', () async {
    final flow = GitHubDeviceFlow(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/device/code')) {
          return http.Response(codeResponse(), 200);
        }
        return http.Response(jsonEncode({'error': 'authorization_pending'}), 200);
      }),
    );

    final code = await flow.start();
    flow.cancel();

    await expectLater(
      flow.awaitToken(code),
      throwsA(isA<GitHubAuthException>().having((e) => e.isCancelled, 'isCancelled', isTrue)),
    );
  });

  test('a reply that is not JSON fails cleanly', () async {
    final flow = GitHubDeviceFlow(
      client: MockClient((_) async => http.Response('<html>down</html>', 502)),
    );

    await expectLater(flow.start(), throwsA(isA<GitHubAuthException>()));
  });

  test('GitHub\'s own wording is kept when it gives one', () async {
    final flow = GitHubDeviceFlow(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': 'device_flow_disabled',
            'error_description': 'Device flow is not enabled for this app',
          }),
          400,
        ),
      ),
    );

    await expectLater(
      flow.start(),
      throwsA(isA<GitHubAuthException>()
          .having((e) => e.message, 'message', contains('Device flow is not enabled'))),
    );
  });
}
