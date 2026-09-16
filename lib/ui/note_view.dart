import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:provider/provider.dart';

import '../markdown/project_links.dart';
import '../state/app_state.dart';
import '../storage/attachment_store.dart';
import 'theme.dart';

/// Renders an item's notes as markdown, resolving image references against the
/// attachment cache.
class NoteView extends StatelessWidget {
  const NoteView({
    super.key,
    required this.markdown,
    this.selectable = true,
    this.onOpenProject,
  });

  final String markdown;
  final bool selectable;

  /// Called when a link to another project is tapped. Without it, such links
  /// are shown but do nothing.
  final void Function(String slug)? onOpenProject;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    // Render wikilinks as real links, so a note pasted from a vault behaves
    // the same as one written here.
    final rendered = ProjectLinks.normalize(markdown, state.projects);

    return MarkdownBody(
      data: rendered,
      selectable: selectable,
      styleSheet: _styleSheet(context),
      imageBuilder: (uri, title, alt) => _NoteImage(
        reference: uri.toString(),
        alt: alt,
        store: state.attachments,
        state: state,
      ),
      onTapLink: (_, href, __) {
        if (href == null) return;

        final slug = ProjectLinks.targetSlug(href);
        if (slug != null && state.projectBySlug(slug) != null) {
          onOpenProject?.call(slug);
          return;
        }

        // Opening external links needs a launcher plugin; until then show the
        // target rather than appearing to do nothing.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(href)),
        );
      },
    );
  }
}

/// The rendered note's look, built from the same type scale the editor uses.
MarkdownStyleSheet _styleSheet(BuildContext context) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final body = NoteTypography.body(theme);

  final mono = body.copyWith(
    fontFamily: 'monospace',
    fontSize: NoteTypography.size - 1.5,
    height: 1.45,
  );

  return MarkdownStyleSheet(
    p: body,
    h1: NoteTypography.heading(theme, 1),
    h2: NoteTypography.heading(theme, 2),
    h3: NoteTypography.heading(theme, 3),
    h4: NoteTypography.heading(theme, 4),
    h5: NoteTypography.heading(theme, 5),
    h6: NoteTypography.heading(theme, 6),
    h1Padding: EdgeInsets.only(top: NoteTypography.spaceAbove(1)),
    h2Padding: EdgeInsets.only(top: NoteTypography.spaceAbove(2)),
    h3Padding: EdgeInsets.only(top: NoteTypography.spaceAbove(3)),
    h4Padding: EdgeInsets.only(top: NoteTypography.spaceAbove(4)),
    a: body.copyWith(color: scheme.primary),
    strong: body.copyWith(fontWeight: FontWeight.w700),
    em: body.copyWith(fontStyle: FontStyle.italic),
    listBullet: body,
    // A quote is marked by a bar beside it rather than a box around it, which
    // keeps the text on the same rhythm as the prose above it.
    blockquote: body.copyWith(color: scheme.onSurfaceVariant),
    blockquotePadding: const EdgeInsets.fromLTRB(16, 2, 0, 2),
    blockquoteDecoration: BoxDecoration(
      border: Border(
        left: BorderSide(color: scheme.primary.withValues(alpha: 0.4), width: 3),
      ),
    ),
    code: mono.copyWith(
      backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.8),
    ),
    codeblockPadding: const EdgeInsets.all(12),
    codeblockDecoration: BoxDecoration(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(8),
    ),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: scheme.outlineVariant)),
    ),
    blockSpacing: 10,
  );
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
