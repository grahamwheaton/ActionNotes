import 'dart:io';

import 'package:path/path.dart' as p;

/// One thing in a folder listing.
class FolderEntry {
  const FolderEntry({
    required this.name,
    required this.isDirectory,
    this.size = 0,
    this.modified = 0,
  });

  final String name;
  final bool isDirectory;

  /// Bytes; zero for a directory.
  final int size;

  /// Milliseconds since the epoch, or zero when the folder does not say.
  /// Zero means "do not trust this to notice a change".
  final int modified;
}

/// The few file operations a folder-backed notebook needs.
///
/// Paths are relative to the notebook's root and use `/` whatever the
/// platform. There are two implementations because "a folder" is two different
/// things: on Windows it is a path that `dart:io` can open, and on Android a
/// folder in OneDrive or Google Drive is not a path at all but a document tree
/// the system hands out access to, reached through the Storage Access
/// Framework.
abstract class FolderBackend {
  /// Whether the root itself is there and can be used.
  Future<bool> exists();

  /// What is directly inside [dir] (`''` is the root), or null when [dir] does
  /// not exist.
  Future<List<FolderEntry>?> list(String dir);

  /// A file's bytes, or null when it is not there.
  Future<List<int>?> read(String path);

  /// Writes a file, making any folders it needs and replacing what was there.
  Future<void> write(String path, List<int> bytes);

  /// Removes a file. Returns whether there was one to remove.
  Future<bool> delete(String path);

  /// Makes a folder and any above it.
  Future<void> makeDirectory(String dir);
}

/// A folder on a path `dart:io` can open — every folder on Windows, and an
/// ordinary directory on any desktop.
class IoFolderBackend implements FolderBackend {
  IoFolderBackend(this.root);

  final String root;

  /// The platform path for a relative one, refusing to leave the root.
  String _abs(String relative) {
    final parts = relative
        .split('/')
        .where((part) => part.isNotEmpty && part != '.')
        .toList();
    if (parts.contains('..')) {
      throw ArgumentError.value(relative, 'relative', 'must stay in the folder');
    }
    return parts.isEmpty ? root : p.joinAll([root, ...parts]);
  }

  @override
  Future<bool> exists() => Directory(root).exists();

  @override
  Future<List<FolderEntry>?> list(String dir) async {
    final directory = Directory(_abs(dir));
    if (!await directory.exists()) return null;

    final entries = <FolderEntry>[];
    // Links are followed (the default), so a file that is really a cloud
    // placeholder — OneDrive's on-demand files are reparse points — is listed
    // as the file it stands for rather than as something to skip.
    await for (final entity in directory.list()) {
      final name = p.basename(entity.path);
      final stat = await entity.stat();
      switch (stat.type) {
        case FileSystemEntityType.file:
          entries.add(
            FolderEntry(
              name: name,
              isDirectory: false,
              size: stat.size,
              modified: stat.modified.millisecondsSinceEpoch,
            ),
          );
        case FileSystemEntityType.directory:
          entries.add(FolderEntry(name: name, isDirectory: true));
        default:
          // A broken link, or something that is neither.
          break;
      }
    }
    return entries;
  }

  @override
  Future<List<int>?> read(String path) async {
    final file = File(_abs(path));
    try {
      return await file.readAsBytes();
    } on PathNotFoundException {
      return null;
    }
  }

  @override
  Future<void> write(String path, List<int> bytes) async {
    final target = File(_abs(path));
    await target.parent.create(recursive: true);

    // Written beside it and moved into place, so a sync app that is watching
    // the folder — or another device reading it — never sees half a file. The
    // name starts with a dot and ends in .partial, which no listing treats as
    // a note.
    final temp = File(
      p.join(target.parent.path, '.${p.basename(target.path)}.partial'),
    );
    await temp.writeAsBytes(bytes, flush: true);
    try {
      await temp.rename(target.path);
    } on FileSystemException {
      // Some filesystems will not rename over a file that exists. Writing it
      // directly is the less careful version of the same thing.
      await target.writeAsBytes(bytes, flush: true);
      try {
        await temp.delete();
      } on FileSystemException {
        // Left behind; harmless, and overwritten by the next write.
      }
    }
  }

  @override
  Future<bool> delete(String path) async {
    final file = File(_abs(path));
    try {
      await file.delete();
      return true;
    } on PathNotFoundException {
      return false;
    }
  }

  @override
  Future<void> makeDirectory(String dir) async {
    await Directory(_abs(dir)).create(recursive: true);
  }
}
