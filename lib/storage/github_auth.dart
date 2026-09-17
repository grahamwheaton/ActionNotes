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
  GitHubDeviceFlow({http.Client? client}) : _injected = client;

  static const _codeUrl = 'https://github.com/login/device/code';
  static const _tokenUrl = 'https://github.com/login/oauth/access_token';

  /// A client supplied by a test. When absent one is made here and replaced
  /// whenever a connection turns out to be dead.
  final http.Client? _injected;
  http.Client? _owned;

  bool _cancelled = false;

  /// The last transport failure, so a sign-in that never got through can say
  /// so instead of blaming an expired code.
  Object? _lastTransportError;

  /// The wait between polls, held so it can be cut short.
  Completer<void>? _sleeping;

  http.Client get _client => _injected ?? (_owned ??= http.Client());

  /// Throws away the pooled connection. The next request opens a new one.
  void _dropConnection() {
    if (_injected != null) return;
    _owned?.close();
    _owned = null;
  }

  /// Abandons an in-flight [awaitToken]. Safe to call more than once.
  void cancel() {
    _cancelled = true;
    _wake();
    _dropConnection();
  }

  /// Asks a waiting poll to go now rather than sitting out the rest of its
  /// interval.
  ///
  /// Worth calling when the app returns to the foreground: approving happens
  /// in a browser, so coming back is the moment the answer is most likely to
  /// have changed — and on Android it is also when the connection used for
  /// the last poll has most likely been torn down while the app was away.
  void pollNow() => _wake();

  void _wake() {
    final sleeping = _sleeping;
    if (sleeping != null && !sleeping.isCompleted) sleeping.complete();
  }

  /// Waits [duration], unless [pollNow] or [cancel] cuts it short.
  Future<void> _waitBetweenPolls(Duration duration) {
    final completer = Completer<void>();
    _sleeping = completer;

    final timer = Timer(duration, _wake);
    return completer.future.whenComplete(() {
      timer.cancel();
      _sleeping = null;
    });
  }

  /// Posts to GitHub, retrying once on a fresh connection.
  ///
  /// A sign-in runs for minutes with gaps between polls, and GitHub closes
  /// keep-alive connections it considers idle. Dart will not retry a POST on
  /// a socket the peer has shut — it surfaces as a ClientException, "software
  /// caused connection abort" on Android — so the first thing to try is the
  /// same request on a connection that is actually open.
  Future<http.Response> _post(String url, Map<String, String> body) async {
    try {
      return await _client.post(
        Uri.parse(url),
        headers: const {'Accept': 'application/json'},
        body: body,
      );
    } on Exception {
      _dropConnection();
      return _client.post(
        Uri.parse(url),
        headers: const {'Accept': 'application/json'},
        body: body,
      );
    }
  }

  /// Asks GitHub to open a sign-in and mint a code for it.
  Future<DeviceCode> start() async {
    _cancelled = false;

    final response = await _post(_codeUrl, {'client_id': githubClientId});

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
      await _waitBetweenPolls(wait);

      if (_cancelled) {
        throw GitHubAuthException('Sign-in cancelled.', isCancelled: true);
      }
      if (code.hasExpired) {
        throw GitHubAuthException(
          _lastTransportError == null
              ? 'The code expired. Start the sign-in again.'
              : 'Could not reach GitHub while waiting for the approval. '
                  'Check the connection and sign in again.',
        );
      }

      final http.Response response;
      try {
        response = await _post(_tokenUrl, {
          'client_id': githubClientId,
          'device_code': code.deviceCode,
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        });
      } on Exception catch (error) {
        // By this point the approval has usually already happened on
        // github.com, so a dropped connection must not end the sign-in: the
        // device code is still good, and the next poll asks again. Giving up
        // here was what turned a moment of bad network into a failed
        // sign-in that had in fact been approved.
        _lastTransportError = error;
        continue;
      }

      _lastTransportError = null;
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
