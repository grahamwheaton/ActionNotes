import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'update_check.dart';

/// Fetches a release's file and hands it to the system to install.
///
/// Until now Download handed the URL to the browser, so the last two taps
/// belonged to the browser rather than to the app. This fetches the file
/// itself and hands it straight to Android's package installer: one tap, then
/// Android's own "update this app?" prompt, which is the one prompt that
/// should be there.
///
/// It cannot be quieter than that, and should not be. Android will not
/// replace an installed app without the person agreeing, and it will not
/// replace one signed with a different key at all — which is why this was
/// worth building only once releases were signed with the upload key and a
/// signed build had proved it could replace another.
class UpdateInstaller {
  UpdateInstaller({
    http.Client? client,
    Future<Directory> Function()? directory,
    Future<bool> Function(String path)? open,
  }) : _client = client ?? http.Client(),
       _directory = directory ?? getApplicationSupportDirectory,
       _open = open ?? _handToSystem;

  final http.Client _client;
  final Future<Directory> Function() _directory;
  final Future<bool> Function(String path) _open;

  /// Whether handing a file to the system means anything here.
  ///
  /// Android has a package installer that takes an APK. On Windows the
  /// release is a zip to unpack wherever you want it, which is not something
  /// an app can do to itself while it is running, so there the link stands.
  static bool get supportedHere => Platform.isAndroid;

  static Future<bool> _handToSystem(String path) async {
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
    final url = update.downloadUrl;
    final name = update.downloadName;
    if (url == null || name == null) return null;

    try {
      final response = await _client.send(
        http.Request('GET', Uri.parse(url))..followRedirects = true,
      );
      if (response.statusCode != 200) return null;

      final directory = await _directory();
      // Named for the release, so a half-finished download of one version is
      // never mistaken for another, and written beside the app's own data
      // rather than into shared storage — nothing else has any business with
      // it and it is deleted on the way out.
      final file = File('${directory.path}/updates/$name');
      await file.parent.create(recursive: true);

      final total = response.contentLength ?? 0;
      var written = 0;
      final sink = file.openWrite();

      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          written += chunk.length;
          if (total > 0) onProgress?.call((written / total).clamp(0.0, 1.0));
        }
      } finally {
        await sink.close();
      }

      // A truncated download is worse than none: Android would refuse it with
      // a message about a corrupt package rather than about a lost
      // connection.
      if (total > 0 && written != total) {
        await file.delete();
        return null;
      }

      onProgress?.call(1);
      return file;
    } on Object {
      return null;
    }
  }

  /// Hands the file to the system, and says whether it took it.
  Future<bool> install(File file) async {
    try {
      return await _open(file.path);
    } on Object {
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
