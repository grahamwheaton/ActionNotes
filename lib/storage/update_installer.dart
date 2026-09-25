import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'update_check.dart';
import 'windows_updater.dart';

/// Downloads and verifies a release before handing it to Android's installer
/// or staging a Windows update and restart.
class UpdateInstaller {
  UpdateInstaller({
    http.Client? client,
    Future<Directory> Function()? directory,
    Future<bool> Function(String path)? open,
  }) : _client = client ?? http.Client(),
       _directory = directory ?? getApplicationSupportDirectory,
       _open = open;

  final http.Client _client;
  final Future<Directory> Function() _directory;
  final Future<bool> Function(String path)? _open;

  String? lastError;
  bool get restartsApp => Platform.isWindows;

  static bool get supportedHere => Platform.isAndroid || Platform.isWindows;

  Future<bool> _handToSystem(String path) async {
    if (Platform.isWindows) {
      final updater = WindowsUpdater();
      final stage = await updater.stage(File(path));
      if (!await updater.launch(stage)) {
        lastError =
            'Windows could not start the updater. Check antivirus '
            'notifications and try again.';
        return false;
      }
      // The caller has awaited all editor buffers and local saves. The native
      // helper has acknowledged readiness and waits for this process to exit.
      exit(0);
    }
    final result = await OpenFilex.open(path);
    return result.type == ResultType.done;
  }

  /// Downloads the update, reporting how far along it is from 0 to 1.
  ///
  /// Returns null if it could not be fetched. Nothing is reported as an
  /// error here: the caller still has the release page to fall back on, and
  /// an update is a convenience rather than something to fail loudly.
  Future<File?> fetch(
    AvailableUpdate update, {
    void Function(double progress)? onProgress,
  }) async {
    lastError = null;
    File? file;
    final url = update.downloadUrl;
    final name = update.downloadName;
    if (url == null || name == null) return null;
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(name) ||
        Uri.tryParse(url)?.scheme != 'https') {
      lastError = 'The update download is not valid.';
      return null;
    }
    final digest = update.downloadDigest;
    if ((name.endsWith('.zip') || digest != null) &&
        (digest == null ||
            !RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest))) {
      lastError =
          'This release has no valid verification checksum. '
          'Open its release page to download it manually.';
      return null;
    }

    try {
      final response = await _client
          .send(http.Request('GET', Uri.parse(url))..followRedirects = true)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) return null;

      final directory = await _directory();
      // Named for the release, so a half-finished download of one version is
      // never mistaken for another, and written beside the app's own data
      // rather than into shared storage — nothing else has any business with
      // it and it is deleted on the way out.
      file = File('${directory.path}/updates/$name');
      await file.parent.create(recursive: true);

      final total = response.contentLength ?? 0;
      var written = 0;
      final sink = file.openWrite();

      try {
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          written += chunk.length;
          if (written > 256 * 1024 * 1024) {
            throw const FormatException('Update download is too large.');
          }
          sink.add(chunk);
          if (total > 0) onProgress?.call((written / total).clamp(0.0, 1.0));
        }
      } finally {
        await sink.close();
      }

      // A truncated download is worse than none: Android would refuse it with
      // a message about a corrupt package rather than about a lost
      // connection.
      if (written == 0 ||
          (total > 0 && written != total) ||
          (update.downloadSize != null && written != update.downloadSize)) {
        await file.delete();
        return null;
      }

      if (digest != null) {
        final actual = await sha256.bind(file.openRead()).first;
        if ('sha256:$actual' != digest.toLowerCase()) {
          lastError = 'The download failed verification. Please try again.';
          await file.delete();
          return null;
        }
      }
      onProgress?.call(1);
      return file;
    } on Object {
      if (file != null && await file.exists()) {
        try {
          await file.delete();
        } on Object {
          /* Best effort cleanup. */
        }
      }
      return null;
    }
  }

  /// Hands the file to the system, and says whether it took it.
  Future<bool> install(File file) async {
    try {
      return await (_open ?? _handToSystem)(file.path);
    } on Object {
      lastError ??=
          'The update could not be prepared. Check that the app '
          'folder is writable and that antivirus has not blocked it.';
      return false;
    }
  }

  /// Throws away anything left behind by an update that did not finish, or
  /// by one that did and has been installed.
  Future<void> tidy() async {
    try {
      final directory = Directory('${(await _directory()).path}/updates');
      if (directory.existsSync()) await directory.delete(recursive: true);
    } on Object {
      // Nothing to do about it, and nothing depends on it having worked.
    }
  }
}
