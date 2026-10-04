import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'folder_backend.dart';
import 'github_client.dart';
import 'remote_store.dart';
import 'saf_folder_backend.dart';

/// A notebook that lives in a folder on this device.
///
/// The folder is whatever the person picked — usually one inside OneDrive,
/// Google Drive or Dropbox, which the provider's own app keeps in step across
/// devices and people. ActionNotes never talks to those services: it reads and
/// writes files, and the sync app carries them. That is why this needs no
/// sign-in and no app registration with anyone.
///
/// It extends [GitHubConfig] only so that it can travel everywhere a config
/// already does; none of the GitHub fields mean anything here and all are
/// empty. The sync code asks [isComplete] and hands the config to
/// [openFolderStore], and neither cares which kind it has.
class FolderConfig extends GitHubConfig {
  const FolderConfig({required this.path, this.displayName = ''})
    : super(owner: '', repo: '', branch: '', token: '');

  /// A filesystem path on Windows, or a `content://` document-tree address on
  /// Android, where a folder in a cloud app has no path.
  final String path;

  /// What the folder is called, for saying so on screen. Paths on Android are
  /// opaque addresses that mean nothing to read.
  final String displayName;

  @override
  bool get isComplete => path.isNotEmpty;

  @override
  String get locationKey => 'folder:$path';

  FolderConfig copyWith({String? path, String? displayName}) => FolderConfig(
    path: path ?? this.path,
    displayName: displayName ?? this.displayName,
  );
}

/// Picks how a folder is opened from what its address looks like.
FolderBackend openFolderBackend(String path) => isDocumentTree(path)
    ? SafFolderBackend(path)
    : IoFolderBackend(path);

/// Opens whichever kind of store a config describes.
RemoteStore openStore(GitHubConfig config) => config is FolderConfig
    ? FolderStore(config)
    : GitHubClient(config);

String _revisionOf(List<int> bytes) => sha1.convert(bytes).toString();

class _Seen {
  const _Seen(this.size, this.modified, this.revision);

  final int size;
  final int modified;
  final String revision;
}

/// Files in a folder, behind the same interface as a GitHub repo.
///
/// **Revisions are content hashes.** GitHub's SHA is what lets a poll say
/// which files moved on without fetching them, and what makes a stale write
/// detectable. A folder has no such thing, but a hash of the bytes is the same
/// idea: it changes exactly when the content does, on any device, however the
/// file got there.
///
/// Hashing means reading, so a revision seen once is remembered against the
/// file's size and modified time and only recomputed when one of those moves.
/// A folder that does not report a modified time is never trusted from the
/// cache.
///
/// **A write checks before it writes**, which is the whole of what stands in
/// for GitHub refusing a stale SHA. It is not atomic across devices — a cloud
/// app can change the file between the check and the write — but the window is
/// a few milliseconds, and what falls through it is a conflict copy made by the
/// sync app, which loses nothing.
class FolderStore implements RemoteStore {
  FolderStore(this.config, {FolderBackend? backend})
    : _backend = backend ?? openFolderBackend(config.path);

  final FolderConfig config;
  final FolderBackend _backend;

  /// Remembered per folder rather than per store: a store is made fresh for
  /// every sync, and a cache that dies with it would hash everything every
  /// time.
  static final Map<String, Map<String, _Seen>> _seen = {};

  Map<String, _Seen> get _cache => _seen.putIfAbsent(config.path, () => {});

  /// Forgets what has been learned about a folder. For tests, which reuse
  /// paths.
  static void forgetAll() => _seen.clear();

  Future<T> _guard<T>(String what, Future<T> Function() action) async {
    try {
      return await action();
    } on StoreException {
      rethrow;
    } on FileSystemException catch (error) {
      final code = error.osError?.errorCode;
      // 5 is Windows' access denied, 13 is POSIX's; neither will be fixed by
      // trying again.
      final denied = code == 5 || code == 13;
      throw StoreException(
        denied ? 403 : 500,
        'Could not $what: ${error.osError?.message ?? error.message}',
      );
    } on ArgumentError catch (error) {
      throw StoreException(400, 'Could not $what: ${error.message}');
    }
  }

  @override
  Future<void> checkAccess() => _guard('open the folder', () async {
    if (!await _backend.exists()) {
      throw StoreException(
        404,
        'That folder is not there any more, or ActionNotes no longer has '
        'access to it.',
      );
    }
    // Listing is what proves it can actually be read, which a folder that
    // exists is not always.
    await _backend.list('');
  });

  /// A folder is as private as whoever else can see it, which this cannot
  /// know — a family folder is shared on purpose. Saying no is the safe answer:
  /// the only thing it gates is writing a key somewhere other people can read.
  @override
  Future<bool> repoIsPrivate() async => false;

  Future<String?> _revision(String path, FolderEntry entry) async {
    final known = _cache[path];
    if (entry.modified > 0 &&
        known != null &&
        known.size == entry.size &&
        known.modified == entry.modified) {
      return known.revision;
    }

    final bytes = await _backend.read(path);
    if (bytes == null) return null;
    final revision = _revisionOf(bytes);
    _cache[path] = _Seen(entry.size, entry.modified, revision);
    return revision;
  }

  static bool _isScratch(String name) =>
      name.startsWith('.') && name.endsWith('.partial');

  @override
  Future<Map<String, String>> listDirectory(String path) =>
      _guard('list $path', () async {
        final entries = await _backend.list(path);
        if (entries == null) return const <String, String>{};

        final listing = <String, String>{};
        for (final entry in entries) {
          if (entry.isDirectory || _isScratch(entry.name)) continue;
          final full = '$path/${entry.name}';
          final revision = await _revision(full, entry);
          if (revision != null) listing[full] = revision;
        }
        return listing;
      });

  @override
  Future<List<RemoteEntry>> listProjects() => _guard('list the projects', () async {
    final entries = await _backend.list(StoreLayout.projectsDir);
    if (entries == null) {
      // Not "no projects". GitHub answers an absent folder with an empty
      // listing and the sync takes that to mean everything was deleted, which
      // is right for a repo and wrong for a folder: this is also what a cloud
      // drive that is not mounted, or has not finished arriving, looks like,
      // and treating it as a deletion would clear the copies held here.
      throw StoreException(
        404,
        'The notebook\'s "projects" folder is not there. If the folder is in '
        'a cloud drive, check that its app is running and has finished '
        'syncing.',
      );
    }

    final found = <RemoteEntry>[];
    for (final entry in entries) {
      if (entry.isDirectory ||
          !entry.name.endsWith('.md') ||
          entry.name.startsWith('.')) {
        continue;
      }
      final path = '${StoreLayout.projectsDir}/${entry.name}';
      final revision = await _revision(path, entry);
      if (revision != null) found.add(RemoteEntry(path: path, sha: revision));
    }
    return found;
  });

  @override
  Future<RemoteFile?> readFile(String path) => _guard('read $path', () async {
    final bytes = await _backend.read(path);
    if (bytes == null) return null;
    return RemoteFile(
      path: path,
      sha: _revisionOf(bytes),
      content: utf8.decode(bytes, allowMalformed: true),
    );
  });

  @override
  Future<List<int>?> readBytes(String path) =>
      _guard('read $path', () => _backend.read(path));

  @override
  Future<String> writeFile({
    required String path,
    required String content,
    required String message,
    String? sha,
  }) => writeBytes(
    path: path,
    bytes: utf8.encode(content),
    message: message,
    sha: sha,
  );

  /// [message] is a commit message and a folder has no commits, so it is
  /// accepted and ignored. History, where it exists, is the sync app's version
  /// history.
  @override
  Future<String> writeBytes({
    required String path,
    required List<int> bytes,
    required String message,
    String? sha,
  }) => _guard('write $path', () async {
    final current = await _backend.read(path);
    if (current != null) {
      // The same two refusals GitHub makes, because the sync code answers
      // each by reading the file and merging.
      if (sha == null) {
        throw StoreException(422, '$path already exists, and no revision was given');
      }
      if (_revisionOf(current) != sha) {
        throw StoreException(409, '$path has changed since it was read');
      }
    }
    // A revision for a file that is no longer there is not a conflict: it was
    // deleted somewhere else, and what is being written now is newer.

    await _backend.write(path, bytes);
    _cache.remove(path);
    return _revisionOf(bytes);
  });

  @override
  Future<void> deleteFile({
    required String path,
    required String sha,
    required String message,
  }) => _guard('delete $path', () async {
    final current = await _backend.read(path);
    if (current == null) throw StoreException(404, '$path is not there');
    if (_revisionOf(current) != sha) {
      throw StoreException(409, '$path has changed since it was read');
    }
    await _backend.delete(path);
    _cache.remove(path);
  });

  @override
  void dispose() {}
}
