import 'dart:convert';
import 'dart:typed_data';

import 'github_client.dart';

/// One string that carries everything needed to reach a shared repo.
///
/// The point is that someone you share with types nothing and signs in to
/// nothing: they paste this and the app has the owner, the repo, the branch
/// and a token. That is the whole of the setup for them, which is the only
/// version of this a non-technical person will actually do.
///
/// **A share code is a key, not a link.** It carries a real GitHub token in
/// readable form — anyone who has the code has whatever that token can do, to
/// everything in that repo, until the token is revoked. It is scrambled only
/// so that it cannot be mistaken for something harmless and so that a
/// half-copied one fails cleanly; it is not encrypted and cannot be. Treat it
/// the way you would treat a door key, and revoke the token on GitHub if it
/// goes astray.
class ShareCode {
  ShareCode._();

  /// Says what this is and which version it is, so a future format can be
  /// told apart from this one rather than being fed to it.
  static const prefix = 'AN1-';

  static String encode(GitHubConfig config) {
    final payload = utf8.encode(
      [
        config.owner.trim(),
        config.repo.trim(),
        config.branch.trim().isEmpty ? 'main' : config.branch.trim(),
        config.token.trim(),
      ].join('\n'),
    );

    final bytes = Uint8List(payload.length + 4)
      ..setRange(0, payload.length, payload)
      ..setRange(payload.length, payload.length + 4, _check(payload));

    return '$prefix${base64Url.encode(bytes).replaceAll('=', '')}';
  }

  /// The repo a code points at, or null when it is not one of ours, has been
  /// damaged in transit, or is missing something it needs.
  ///
  /// Null rather than an exception, and one answer for every kind of wrong:
  /// there is nothing useful a person can do differently on being told
  /// *which* way a pasted code is broken, and guessing at half a code is how
  /// you end up pointed at the wrong repo.
  static GitHubConfig? decode(String code) {
    final trimmed = code.trim();
    if (!trimmed.startsWith(prefix)) return null;

    try {
      final body = trimmed.substring(prefix.length);
      // Base64url without padding, which is what encode writes and what
      // survives being pasted into a message that might reflow it.
      final bytes = base64Url.decode(
        body.padRight((body.length + 3) ~/ 4 * 4, '='),
      );
      if (bytes.length < 5) return null;

      final payload = Uint8List.sublistView(bytes, 0, bytes.length - 4);
      final checksum = Uint8List.sublistView(bytes, bytes.length - 4);
      final expected = _check(payload);
      for (var i = 0; i < 4; i++) {
        if (checksum[i] != expected[i]) return null;
      }

      final parts = utf8.decode(payload).split('\n');
      if (parts.length != 4) return null;

      final config = GitHubConfig(
        owner: parts[0],
        repo: parts[1],
        branch: parts[2],
        token: parts[3],
      );
      return config.isComplete ? config : null;
    } on Object {
      return null;
    }
  }

  /// Whether something looks like one of our codes at all, for telling a
  /// pasted code from a pasted anything-else without decoding it.
  static bool looksLikeOne(String text) => text.trim().startsWith(prefix);

  /// FNV-1a, four bytes of it.
  ///
  /// Here to catch a code that was cut short or had a character mangled on
  /// its way through a chat app — not to make it hard to forge one, which no
  /// checksum could do when the format is public.
  static Uint8List _check(List<int> bytes) {
    var hash = 0x811c9dc5;
    for (final byte in bytes) {
      hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
    }
    return Uint8List.fromList([
      (hash >> 24) & 0xff,
      (hash >> 16) & 0xff,
      (hash >> 8) & 0xff,
      hash & 0xff,
    ]);
  }
}
