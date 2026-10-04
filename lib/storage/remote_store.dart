/// Where a notebook's files live, as far as the sync code is concerned.
///
/// The sync code was written against GitHub's REST API and never needed to
/// know that was a choice. This is the shape it actually relies on, pulled out
/// so that something else — a folder that OneDrive or Google Drive keeps in
/// step — can stand in for the repo without the sync code changing.
///
/// The contract is GitHub's, because that is what everything above was built
/// on, and it is small:
///
///  * Every file has a *revision*, an opaque string that changes whenever its
///    content does. A listing carries it, so a poll can say which files have
///    moved on without fetching them (the "sha" in the names below).
///  * A write names the revision it was based on. If the file has moved on
///    since, the write is refused with a [StoreException] whose status is 409
///    (or 422 when the file exists and no revision was named), and the caller
///    merges and tries again. That refusal is how two people editing the same
///    file are noticed at all, so any store has to be able to make it.
///  * Paths are relative, use `/`, and look like `projects/trip.md`.
library;

/// A file as the store reports it.
class RemoteFile {
  const RemoteFile({
    required this.path,
    required this.sha,
    required this.content,
  });

  final String path;
  final String sha;
  final String content;
}

/// One file in a listing: where it is and what revision it is at, without its
/// contents.
class RemoteEntry {
  const RemoteEntry({required this.path, required this.sha});

  final String path;
  final String sha;
}

/// A store refused or failed a request.
///
/// The status codes are HTTP's whatever the store is, because callers branch on
/// them: 409 and 422 mean "someone else got there first", and 401, 403 and 404
/// mean retrying will not help.
class StoreException implements Exception {
  StoreException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  /// True when retrying will not help — bad token, missing repo, and so on.
  bool get isFatal =>
      statusCode == 401 || statusCode == 403 || statusCode == 404;

  @override
  String toString() => 'Store $statusCode: $message';
}

/// Names of the folders a notebook keeps its files in. The same in a repo and
/// in a folder, which is what lets a notebook be moved from one to the other
/// by copying it.
abstract final class StoreLayout {
  static const projectsDir = 'projects';

  /// Where completed items go when a list is tidied. Deliberately not under
  /// `projects/`, which is scanned: an archive is kept, not shown.
  static const archiveDir = 'archive';
  static const attachmentsDir = 'attachments';

  /// App-owned bookkeeping, out of the way of the part anybody reads by hand.
  static const metaDir = '.actionnotes';
}

/// The handful of operations the app needs from wherever a notebook lives.
abstract class RemoteStore {
  /// Verifies the store can be reached and read. Throws [StoreException] if
  /// not.
  Future<void> checkAccess();

  /// Whether the store is private, which decides whether anything sensitive
  /// (a share code carries a token) may be written into it.
  Future<bool> repoIsPrivate();

  /// Lists a directory's files with their revisions, which a delete needs.
  /// An absent directory is not an error. Keys are full relative paths.
  Future<Map<String, String>> listDirectory(String path);

  /// Lists the markdown files in `projects/` with the revision each one is at,
  /// which is what makes a poll cheap.
  Future<List<RemoteEntry>> listProjects();

  /// A file's text, or null when it is not there.
  Future<RemoteFile?> readFile(String path);

  /// A file's raw bytes, or null when it is not there.
  Future<List<int>?> readBytes(String path);

  /// Creates or updates a text file. [sha] must be the revision last read for
  /// an update; a stale one is refused with a 409. Returns the new revision.
  Future<String> writeFile({
    required String path,
    required String content,
    required String message,
    String? sha,
  });

  /// As [writeFile], for bytes.
  Future<String> writeBytes({
    required String path,
    required List<int> bytes,
    required String message,
    String? sha,
  });

  Future<void> deleteFile({
    required String path,
    required String sha,
    required String message,
  });

  void dispose();
}
