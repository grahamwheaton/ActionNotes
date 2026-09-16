import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// The ActionNotes GitHub App. A client ID is not a secret: the device flow
/// exists precisely for apps that cannot keep one, so there is no companion
/// secret to ship and nothing here that has to be kept out of the repo.
const githubClientId = 'Iv23limPVh5tK5caSuxj';

/// What GitHub hands back when a sign-in starts: the code the person types
/// into the browser, and the device code the app quietly polls with.
class DeviceCode {
  const DeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.interval,
    required this.expiresAt,
  });

  final String deviceCode;

  /// The short code the person reads off the screen, e.g. `WDJB-MJHT`.
  final String userCode;

  /// Where they type it in — github.com/login/device.
  final Uri verificationUri;

  /// How long GitHub asks us to wait between polls.
  final Duration interval;

  final DateTime expiresAt;

  bool get hasExpired => DateTime.now().isAfter(expiresAt);
}

/// A sign-in that did not finish. [isCancelled] separates the person changing
/// their mind from anything that deserves an error message.
class GitHubAuthException implements Exception {
  GitHubAuthException(this.message, {this.isCancelled = false});

  final String message;
  final bool isCancelled;

  @override
  String toString() => message;
}

/// GitHub's device flow: ask for a code, let the person approve it in a
/// browser, poll until a token comes back.
///
/// The whole point is that nothing sensitive is typed into this app — the
/// approval happens on github.com, and all that crosses back is the token.
class GitHubDeviceFlow {
  GitHubDeviceFlow({http.Client? client}) : _client = client ?? http.Client();

  static const _codeUrl = 'https://github.com/login/device/code';
  static const _tokenUrl = 'https://github.com/login/oauth/access_token';

  final http.Client _client;
  bool _cancelled = false;

  /// Abandons an in-flight [awaitToken]. Safe to call more than once.
  void cancel() => _cancelled = true;

  /// Asks GitHub to open a sign-in and mint a code for it.
  Future<DeviceCode> start() async {
    _cancelled = false;

    final response = await _client.post(
      Uri.parse(_codeUrl),
      headers: const {'Accept': 'application/json'},
      body: {'client_id': githubClientId},
    );

    final body = _decode(response);
    if (response.statusCode != 200 || body['device_code'] == null) {
      throw GitHubAuthException(
        _describe(body) ?? 'GitHub would not start a sign-in (${response.statusCode}).',
      );
    }

    // Both intervals are in seconds, and GitHub may raise the poll interval
    // mid-flight with a slow_down, so keep it rather than hard-coding five.
    final interval = (body['interval'] as num?)?.toInt() ?? 5;
    final expiresIn = (body['expires_in'] as num?)?.toInt() ?? 900;

    return DeviceCode(
      deviceCode: body['device_code'] as String,
      userCode: body['user_code'] as String? ?? '',
      verificationUri: Uri.parse(
        body['verification_uri'] as String? ?? 'https://github.com/login/device',
      ),
      interval: Duration(seconds: interval),
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
    );
  }

  /// Polls until the person approves, refuses, or the code runs out of time.
  ///
  /// Returns the access token. Throws [GitHubAuthException] otherwise.
  Future<String> awaitToken(DeviceCode code) async {
    var wait = code.interval;

    while (true) {
      await Future<void>.delayed(wait);

      if (_cancelled) {
        throw GitHubAuthException('Sign-in cancelled.', isCancelled: true);
      }
      if (code.hasExpired) {
        throw GitHubAuthException('The code expired. Start the sign-in again.');
      }

      final response = await _client.post(
        Uri.parse(_tokenUrl),
        headers: const {'Accept': 'application/json'},
        body: {
          'client_id': githubClientId,
          'device_code': code.deviceCode,
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        },
      );

      final body = _decode(response);
      final token = body['access_token'] as String?;
      if (token != null && token.isNotEmpty) return token;

      switch (body['error'] as String?) {
        case 'authorization_pending':
          // Nobody has clicked approve yet. This is the normal case.
          break;
        case 'slow_down':
          // GitHub is telling us to back off; it names the new interval.
          final next = (body['interval'] as num?)?.toInt();
          wait = Duration(seconds: next ?? wait.inSeconds + 5);
          break;
        case 'expired_token':
          throw GitHubAuthException('The code expired. Start the sign-in again.');
        case 'access_denied':
          throw GitHubAuthException('Sign-in was refused on GitHub.', isCancelled: true);
        default:
          throw GitHubAuthException(
            _describe(body) ?? 'GitHub refused the sign-in (${response.statusCode}).',
          );
      }
    }
  }

  Map<String, dynamic> _decode(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } on FormatException {
      // An HTML error page, a captive portal, anything that is not JSON.
      return const {};
    }
  }

  /// GitHub's own wording for a failure, when it gave one worth showing.
  String? _describe(Map<String, dynamic> body) {
    final description = body['error_description'] as String?;
    if (description != null && description.isNotEmpty) return description;

    final error = body['error'] as String?;
    if (error != null && error.isNotEmpty) return error;

    return null;
  }
}
