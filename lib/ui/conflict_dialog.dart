import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../markdown/project_merge.dart';
import '../models/project.dart';
import '../state/app_state.dart';
import '../storage/sync_service.dart';

/// Shows both versions of a conflicted project side by side and asks which to
/// keep. Every option leaves local and GitHub in agreement, so the project
/// cannot stay stuck.
class ConflictDialog extends StatelessWidget {
  const ConflictDialog({super.key, required this.conflict});

  final ProjectConflict conflict;

  static Future<void> show(BuildContext context, ProjectConflict conflict) {
    return showDialog<void>(
      context: context,
      builder: (_) => ConflictDialog(conflict: conflict),
    );
  }

  Future<void> _resolve(
    BuildContext context,
    ConflictResolution resolution,
  ) async {
    final state = context.read<AppState>();
    Navigator.of(context).pop();
    await state.resolveConflict(conflict.slug, resolution);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final merged = ProjectMerge.merge(
      local: conflict.local,
      remote: conflict.remote,
    );

    return AlertDialog(
      title: Text('"${conflict.local.title}" changed in two places'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'You edited this project on this device while it also changed '
                'on GitHub. Nothing has been lost — pick which version to keep.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _VersionCard(
                      label: 'On this device',
                      project: conflict.local,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _VersionCard(
                      label: 'On GitHub',
                      project: conflict.remote,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _VersionCard(
                label: 'Merged — keeps every item from both',
                project: merged,
                highlight: true,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _resolve(context, ConflictResolution.keepRemote),
          child: const Text("Use GitHub's"),
        ),
        TextButton(
          onPressed: () => _resolve(context, ConflictResolution.keepLocal),
          child: const Text('Keep mine'),
        ),
        FilledButton(
          onPressed: () => _resolve(context, ConflictResolution.merge),
          child: const Text('Merge both'),
        ),
      ],
    );
  }
}

class _VersionCard extends StatelessWidget {
  const _VersionCard({
    required this.label,
    required this.project,
    this.highlight = false,
  });

  final String label;
  final Project project;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: highlight
            ? theme.colorScheme.secondaryContainer
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${project.items.length} items, ${project.doneCount} done',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          for (final item in project.items.take(8))
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '${item.done ? '☑' : '☐'} ${item.starred ? '⭐ ' : ''}${item.text}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (project.items.length > 8)
            Text(
              '…and ${project.items.length - 8} more',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}
