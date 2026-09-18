import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// A release newer than the one running.
class AvailableUpdate {
  const AvailableUpdate({
    required this.version,
    required this.notes,
    required this.pageUrl,
    this.downloadUrl,
    this.downloadName,
  });

  /// As the tag reads, without the `v`.
  final String version;
  final String notes;

  /// The release on github.com, which is the fallback when there is no asset
  /// for this platform.
  final String pageUrl;

  /// The file for the running platform — the APK on Android, the zip on
  /// Windows — or null if the release has none.
  final String? downloadUrl;
  final String? downloadName;
}

/// Asks GitHub whether there is a newer release than the running build.
///
/// Read-only and unauthenticated: the releases of a public repo need no
/// token, and an update check that depended on being signed in would not work
/// before signing in, which is when a stale build is most likely.
class UpdateCheck {
  UpdateCheck({
    this.owner = 'grahamwheaton',
    this.repo = 'ActionNotes',
    http.Client? client,
    String? platformSuffix,
  })  : _client = client ?? http.Client(),
        _platformSuffix = platformSuffix ?? _suffixForPlatform();

  final String owner;
  final String repo;
  final http.Client _client;

  /// What the asset for this platform ends with. Nothing on a platform that
  /// has no build, in which case only the release page is offered.
  final String? _platformSuffix;

  static String? _suffixForPlatform() {
    if (Platform.isAndroid) return '.apk';
    if (Platform.isWindows) return '-windows.zip';
    return null;
  }

  /// The newer release, or null when the running build is current — or when
  /// the question could not be answered, which is not worth reporting: an
  /// update check is a convenience, not a feature to fail loudly.
  Future<AvailableUpdate?> latest(String runningVersion) async {
    try {
      final response = await _client.get(
        Uri.parse('https://api.github.com/repos/$owner/$repo/releases/latest'),
        headers: const {
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
        },
      );
      if (response.statusCode != 200) return null;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final tag = (json['tag_name'] as String? ?? '').trim();
      final version = tag.startsWith('v') ? tag.substring(1) : tag;
      if (version.isEmpty) return null;
      if (!isNewer(version, runningVersion)) return null;

      String? url;
      String? name;
      final suffix = _platformSuffix;
      if (suffix != null) {
        for (final asset in (json['assets'] as List? ?? const [])) {
          if (asset is! Map<String, dynamic>) continue;
          final assetName = asset['name'] as String? ?? '';
          if (assetName.endsWith(suffix)) {
            name = assetName;
            url = asset['browser_download_url'] as String?;
            break;
          }
        }
      }

      return AvailableUpdate(
        version: version,
        notes: json['body'] as String? ?? '',
        pageUrl: json['html_url'] as String? ??
            'https://github.com/$owner/$repo/releases/latest',
        downloadUrl: url,
        downloadName: name,
      );
    } catch (_) {
      return null;
    }
  }

  /// Compares two dotted versions, ignoring anything after a `+`.
  ///
  /// Numeric part by part rather than as strings, so 0.10.0 is newer than
  /// 0.9.0 — which a string comparison gets wrong, and which this project
  /// will reach.
  static bool isNewer(String candidate, String running) {
    final a = _parts(candidate);
    final b = _parts(running);

    for (var i = 0; i < (a.length > b.length ? a.length : b.length); i++) {
      final left = i < a.length ? a[i] : 0;
      final right = i < b.length ? b[i] : 0;
      if (left != right) return left > right;
    }
    return false;
  }

  static List<int> _parts(String version) {
    final cleaned = version.split('+').first.trim();
    return [
      for (final part in cleaned.split('.'))
        int.tryParse(part.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0,
    ];
  }

  void dispose() => _client.close();
}
