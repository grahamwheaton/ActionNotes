
import 'package:flutter/services.dart';

import 'folder_backend.dart';
import 'remote_store.dart';

/// Whether an address is an Android document tree rather than a path.
bool isDocumentTree(String path) => path.startsWith('content://');

/// The Android side of folder access; see MainActivity.kt.
const folderChannel = MethodChannel('uk.co.actionnotes/folders');

/// A folder reached through Android's Storage Access Framework.
///
/// This is how a folder inside OneDrive, Google Drive or Dropbox is reached on
/// a phone: the person picks it, the system keeps the grant, and the provider
/// answers for the files. It does exactly what [IoFolderBackend] does, through
/// a channel instead of a path, so the store above neither knows nor cares
/// which it has.
class SafFolderBackend implements FolderBackend {
  SafFolderBackend(this.tree);

  /// The `content://` address of the tree the person picked.
  final String tree;

  Future<T?> _call<T>(String method, [Map<String, Object?> arguments = const {}]) async {
    try {
      return await folderChannel.invokeMethod<T>(method, {
        'tree': tree,
        ...arguments,
      });
    } on PlatformException catch (error) {
      throw StoreException(
        error.code == 'denied' ? 403 : 500,
        error.message ?? 'The folder could not be reached.',
      );
    } on MissingPluginException {
      throw StoreException(
        501,
        'Folders in other apps are not available on this device.',
      );
    }
  }

  @override
  Future<bool> exists() async => (await _call<bool>('exists')) ?? false;

  @override
  Future<List<FolderEntry>?> list(String dir) async {
    final raw = await _call<List<Object?>>('list', {'path': dir});
    if (raw == null) return null;

    return [
      for (final item in raw)
        if (item is Map)
          FolderEntry(
            name: item['name'] as String? ?? '',
            isDirectory: item['dir'] as bool? ?? false,
            size: (item['size'] as num?)?.toInt() ?? 0,
            modified: (item['modified'] as num?)?.toInt() ?? 0,
          ),
    ];
  }

  @override
  Future<List<int>?> read(String path) =>
      _call<Uint8List>('read', {'path': path});

  @override
  Future<void> write(String path, List<int> bytes) async {
    await _call<void>('write', {
      'path': path,
      'bytes': bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    });
  }

  @override
  Future<bool> delete(String path) async =>
      (await _call<bool>('delete', {'path': path})) ?? false;

  @override
  Future<void> makeDirectory(String dir) async {
    await _call<void>('mkdir', {'path': dir});
  }
}
