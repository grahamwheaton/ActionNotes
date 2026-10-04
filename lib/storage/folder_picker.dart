import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'saf_folder_backend.dart';

/// A folder the person chose.
class PickedFolder {
  const PickedFolder({required this.path, required this.name});

  /// A filesystem path, or a `content://` address on Android.
  final String path;

  /// What to call it on screen.
  final String name;
}

/// Asks the person for a folder, the way their platform does it.
class FolderPicker {
  FolderPicker._();

  /// Stands in for the system dialog in tests, which cannot open one.
  @visibleForTesting
  static Future<PickedFolder?> Function()? override;

  static Future<PickedFolder?> pick() async {
    final stub = override;
    if (stub != null) return stub();

    if (Platform.isAndroid) {
      // The system picker is the only way to a folder in another app, and the
      // grant it hands back is the permission.
      final picked = await folderChannel.invokeMapMethod<String, Object?>(
        'pick',
      );
      if (picked == null) return null;
      final uri = picked['uri'] as String?;
      if (uri == null || uri.isEmpty) return null;
      return PickedFolder(path: uri, name: picked['name'] as String? ?? '');
    }

    final path = await getDirectoryPath(confirmButtonText: 'Use this folder');
    if (path == null || path.isEmpty) return null;
    return PickedFolder(path: path, name: p.basename(path));
  }
}
