import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:pasteboard/pasteboard.dart';

/// What can be done with an attachment, in one place so the note editor, a
/// rendered note and the full-size viewer all offer the same things.
class ImageActions {
  ImageActions._();

  /// Whether the running platform can show a file in its file manager.
  static bool get canReveal =>
      !Platform.isAndroid && !Platform.isIOS;

  /// Puts the picture on the clipboard. Returns what to tell the person.
  static Future<String> copy(File file) async {
    try {
      await Pasteboard.writeImage(Uint8List.fromList(await file.readAsBytes()));
      return 'Image copied.';
    } catch (_) {
      // Android has no image clipboard through this plugin, and a failure
      // here is not worth an error dialog.
      return 'Could not copy the image on this platform.';
    }
  }

  /// Saves a copy wherever the person asks. Returns what to tell them, or
  /// null if they backed out.
  static Future<String?> saveCopy(File file, String suggestedName) async {
    final location = await getSaveLocation(suggestedName: suggestedName);
    if (location == null) return null;

    try {
      await File(location.path).writeAsBytes(await file.readAsBytes());
      return 'Saved to ${location.path}';
    } catch (error) {
      return 'Could not save the image: $error';
    }
  }

  /// Opens the file manager with the file selected, which is the desktop
  /// answer to "where is this actually kept".
  static Future<String?> reveal(File file) async {
    final path = file.absolute.path;
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', ['/select,$path']);
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else {
        // Freedesktop's file manager interface, with the directory as the
        // fallback for anything that does not implement it.
        final result = await Process.run('xdg-open', [file.parent.path]);
        if (result.exitCode != 0) return 'No file manager answered.';
      }
      return null;
    } catch (error) {
      return 'Could not open the folder: $error';
    }
  }
}

/// Shows one attachment as large as the window allows, zoomable.
///
/// A picture in a note is drawn at the width of the note, which makes a
/// screenshot of anything detailed unreadable in the app while being
/// perfectly readable on GitHub. This is the way in to the real thing.
Future<void> showImageViewer(
  BuildContext context, {
  required File file,
  String? alt,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (_) => _ImageViewer(file: file, alt: alt),
  );
}

class _ImageViewer extends StatelessWidget {
  const _ImageViewer({required this.file, this.alt});

  final File file;
  final String? alt;

  String get _name {
    final name = alt?.trim();
    if (name != null && name.isNotEmpty) return name;
    return file.uri.pathSegments.last;
  }

  /// Runs an action and reports it, holding the messenger rather than the
  /// context: the answer arrives after an await, by which time reaching for
  /// the context again is exactly what it warns about.
  Future<void> _run(
    BuildContext context,
    Future<String?> Function() action,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final message = await action();
    if (message == null) return;
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog.fullscreen(
      backgroundColor: Colors.transparent,
      child: Column(
        children: [
          Material(
            color: theme.colorScheme.surface.withValues(alpha: 0.92),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                Expanded(
                  child: Text(
                    _name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Copy',
                  icon: const Icon(Icons.copy_all_outlined),
                  onPressed: () => _run(context, () => ImageActions.copy(file)),
                ),
                IconButton(
                  tooltip: 'Save a copy',
                  icon: const Icon(Icons.download_outlined),
                  onPressed: () =>
                      _run(context, () => ImageActions.saveCopy(file, _name)),
                ),
                if (ImageActions.canReveal)
                  IconButton(
                    tooltip: 'Show in folder',
                    icon: const Icon(Icons.folder_open_outlined),
                    onPressed: () =>
                        _run(context, () => ImageActions.reveal(file)),
                  ),
                const SizedBox(width: 4),
              ],
            ),
          ),
          Expanded(
            child: GestureDetector(
              // Tapping the backdrop closes it, the way a lightbox does.
              onTap: () => Navigator.of(context).pop(),
              child: InteractiveViewer(
                maxScale: 8,
                child: Center(
                  child: Image.file(file, fit: BoxFit.contain),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
