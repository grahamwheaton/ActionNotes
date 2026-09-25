import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// Stages a complete Windows bundle before asking the separate native helper
/// to replace it. The helper has no Flutter DLL dependencies and runs from the
/// staging directory, so neither executable is overwritten while it is running.
class WindowsUpdater {
  WindowsUpdater({String? executable})
    : executable = executable ?? Platform.resolvedExecutable;

  final String executable;

  Future<Directory> stage(File zip) async {
    final install = Directory(p.dirname(executable));
    final directory = await install.createTemp('.actionnotes-update-');
    try {
      final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
      final payload = Directory(p.join(directory.path, 'payload'));
      await payload.create();
      final names = <String>{};
      var expandedSize = 0;
      for (final entry in archive) {
        final name = entry.name.replaceAll('\\', '/');
        final parts = name.replaceFirst(RegExp(r'/$'), '').split('/');
        // Windows also treats trailing dots/spaces, device names and alternate
        // data streams specially. Reject them instead of normalising an alias.
        if (entry.isSymbolicLink ||
            parts.any(
              (part) =>
                  part.isEmpty ||
                  part == '.' ||
                  part == '..' ||
                  RegExp(r'[<>:"|?*\x00-\x1f]').hasMatch(part) ||
                  part.endsWith('.') ||
                  part.endsWith(' ') ||
                  RegExp(
                    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)',
                    caseSensitive: false,
                  ).hasMatch(part),
            ) ||
            !names.add(parts.join('/').toLowerCase())) {
          throw const FormatException('Unsafe or duplicate update path.');
        }
        final root = parts.first;
        if (root != 'data' &&
            !(parts.length == 1 &&
                entry.isFile &&
                (root == 'actionnotes.exe' ||
                    root == 'actionnotes_updater.exe' ||
                    root.endsWith('.dll')))) {
          throw const FormatException('Unexpected file in Windows update.');
        }
        expandedSize += entry.size;
        if (expandedSize > 512 * 1024 * 1024 || names.length > 20000) {
          throw const FormatException('Update is too large.');
        }
        final destination = p.joinAll([payload.path, ...parts]);
        if (entry.isFile) {
          final file = File(destination);
          await file.parent.create(recursive: true);
          await file.writeAsBytes(entry.content, flush: true);
        } else {
          await Directory(destination).create(recursive: true);
        }
      }
      for (final name in [
        'actionnotes.exe',
        'flutter_windows.dll',
        'actionnotes_updater.exe',
        'data/app.so',
        'data/icudtl.dat',
        'data/flutter_assets/AssetManifest.bin',
      ]) {
        final file = File(p.join(payload.path, name));
        if (!await file.exists() || await file.length() == 0) {
          throw FormatException('The update is missing $name.');
        }
        if (name.endsWith('.exe') || name.endsWith('.dll')) {
          final input = await file.open();
          try {
            final magic = await input.read(2);
            if (magic.length != 2 || magic[0] != 77 || magic[1] != 90) {
              throw const FormatException('Invalid Windows executable.');
            }
          } finally {
            await input.close();
          }
        }
      }
      // Execute the helper that shipped with the running, known version.
      await File(
        p.join(install.path, 'actionnotes_updater.exe'),
      ).copy(p.join(directory.path, 'updater.exe'));
      return directory;
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<bool> launch(Directory stage) async {
    final process = await Process.start(p.join(stage.path, 'updater.exe'), [
      p.dirname(executable),
      stage.path,
      '$pid',
    ], mode: ProcessStartMode.detached);
    final ready = File(p.join(stage.path, 'ready'));
    final failed = File(p.join(stage.path, 'error.txt'));
    for (var attempt = 0; attempt < 100; attempt++) {
      if (await ready.exists()) return true;
      if (await failed.exists()) return false;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    Process.killPid(process.pid);
    return false;
  }

  /// Only acknowledge a launch requested by our updater inside this install.
  static File? launchMarker(List<String> arguments, String flag) {
    if (arguments.length != 2 || arguments.first != flag) return null;
    final path = p.normalize(p.absolute(arguments.last));
    final stage = p.dirname(path);
    final install = p.dirname(Platform.resolvedExecutable);
    if (!p.equals(p.dirname(stage), install) ||
        !p.basename(stage).startsWith('.actionnotes-update-') ||
        p.basename(path) !=
            (flag == '--update-ready' ? 'started' : 'error.txt')) {
      return null;
    }
    return File(path);
  }
}
