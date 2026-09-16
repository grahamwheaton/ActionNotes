import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../storage/attachment_store.dart';

/// Renders an item's notes as markdown, resolving image references against the
/// attachment cache.
class NoteView extends StatelessWidget {
  const NoteView({super.key, required this.markdown, this.selectable = true});

  final String markdown;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return MarkdownBody(
      data: markdown,
      selectable: selectable,
      imageBuilder: (uri, title, alt) => _NoteImage(
        reference: uri.toString(),
        alt: alt,
        store: state.attachments,
        state: state,
      ),
      onTapLink: (_, href, __) {
        // Opening external links needs a launcher plugin; until then say so
        // rather than appearing to do nothing.
        if (href == null) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(href)),
        );
      },
    );
  }
}

/// An image inside a note. Attachments live in a private repo, so they are
/// fetched through the API and cached rather than loaded from a URL.
class _NoteImage extends StatefulWidget {
  const _NoteImage({
    required this.reference,
    required this.alt,
    required this.store,
    required this.state,
  });

  final String reference;
  final String? alt;
  final AttachmentStore store;
  final AppState state;

  @override
  State<_NoteImage> createState() => _NoteImageState();
}

class _NoteImageState extends State<_NoteImage> {
  late Future<File?> _file;

  @override
  void initState() {
    super.initState();
    _file = _load();
  }

  Future<File?> _load() async {
    final repoPath = AttachmentStore.resolveRepoPath(widget.reference);
    if (repoPath == null) return null;
    return widget.store.resolve(repoPath, widget.state.config);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return FutureBuilder<File?>(
      future: _file,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: SizedBox(
              height: 24,
              width: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }

        final file = snapshot.data;
        if (file == null) {
          return Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.image_not_supported_outlined,
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.alt?.isNotEmpty == true
                        ? '${widget.alt} (not available offline)'
                        : 'Image not available offline',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(file, fit: BoxFit.contain),
          ),
        );
      },
    );
  }
}
